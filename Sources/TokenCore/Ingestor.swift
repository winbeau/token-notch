import Foundation

/// 一类 agent 的日志位置。
public struct LogSource: Sendable {
    public var agent: Agent
    public var roots: [URL]

    public init(agent: Agent, roots: [URL]) {
        self.agent = agent
        self.roots = roots
    }

    public static var defaults: [LogSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            LogSource(agent: .claude, roots: [home.appendingPathComponent(".claude/projects")]),
            LogSource(agent: .codex, roots: [home.appendingPathComponent(".codex/sessions"),
                                             home.appendingPathComponent(".codex/archived_sessions")]),
        ]
    }
}

public struct IngestResult: Sendable {
    public var filesRead = 0
    public var events = 0
    public var touchedAgents: Set<Agent> = []
}

/// 把日志增量导入 Store。
///
/// 每个文件记一个字节游标：只读游标之后、以换行结尾的完整行。文件变短或游标前
/// 64 字节的指纹对不上（被重写），就从头重读；事件按键去重，所以重读不会重复计数。
public final class Ingestor: @unchecked Sendable {
    let store: Store
    public let sources: [LogSource]

    public init(store: Store, sources: [LogSource] = LogSource.defaults) {
        self.store = store
        // 统一成解析过符号链接的路径：目录遍历、FSEvents 和调用方给的路径才能对上同一个游标。
        self.sources = sources.map {
            LogSource(agent: $0.agent, roots: $0.roots.map { URL(fileURLWithPath: Self.canonical($0.path)) })
        }
    }

    /// realpath：/var → /private/var。（URL.resolvingSymlinksInPath 反而会去掉 /private。）
    /// 文件不存在时原样返回。
    static func canonical(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// 扫描所有来源，只读有变化的文件。首次运行即全量回填。
    @discardableResult
    public func scanAll() throws -> IngestResult {
        let cursors = try store.allCursors()
        var result = IngestResult()
        for source in sources {
            for path in Self.jsonlFiles(under: source.roots) {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if let c = cursors[path], c.offset == size, c.mtime == mtime { continue }
                let n = try ingestFile(path, agent: source.agent)
                result.filesRead += 1
                result.events += n
                if n > 0 { result.touchedAgents.insert(source.agent) }
            }
        }
        return result
    }

    /// 只处理给定路径（文件监听回调用）。不属于任何来源的路径忽略。
    @discardableResult
    public func ingest(paths: [String]) throws -> IngestResult {
        var result = IngestResult()
        for path in Set(paths.map(Self.canonical)) where path.hasSuffix(".jsonl") {
            guard let agent = agent(for: path), FileManager.default.fileExists(atPath: path) else { continue }
            let n = try ingestFile(path, agent: agent)
            result.filesRead += 1
            result.events += n
            if n > 0 { result.touchedAgents.insert(agent) }
        }
        return result
    }

    public func agent(for path: String) -> Agent? {
        let path = Self.canonical(path)
        for s in sources where s.roots.contains(where: { path.hasPrefix($0.path + "/") }) {
            return s.agent
        }
        return nil
    }

    static func jsonlFiles(under roots: [URL]) -> [String] {
        var out: [String] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                out.append(url.path)
            }
        }
        return out
    }

    func ingestFile(_ path: String, agent: Agent) throws -> Int {
        switch agent {
        case .claude: return try ingest(path, agent: agent, parser: ClaudeParser.self)
        case .codex: return try ingest(path, agent: agent, parser: CodexParser.self)
        }
    }

    private func ingest<P: LogParser>(_ path: String, agent: Agent, parser: P.Type) throws -> Int {
        guard let fh = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? fh.close() }
        let size = Int64(try fh.seekToEnd())
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0

        var offset: Int64 = 0
        var p = P()
        if let c = try store.cursor(for: path), c.offset <= size,
           c.offset == 0 || Self.fingerprint(fh, end: c.offset) == c.fingerprint {
            offset = c.offset
            if let s = c.state, let decoded = try? JSONDecoder().decode(P.self, from: s) { p = decoded }
        }
        if offset == size {
            try store.save(.init(path: path, agent: agent, offset: offset,
                                 fingerprint: Self.fingerprint(fh, end: offset), mtime: mtime,
                                 state: try? JSONEncoder().encode(p)))
            return 0
        }

        try fh.seek(toOffset: UInt64(offset))
        let data = try fh.readToEnd() ?? Data()
        // 用 memchr 找行边界（Data.firstIndex 逐字节走泛型路径，几 GB 日志上慢一个量级）。
        var lines: [Range<Int>] = []
        var consumed = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var pos = 0
            while pos < buf.count, let nl = memchr(base + pos, 0x0A, buf.count - pos) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > pos { lines.append(pos..<end) }
                pos = end + 1
            }
            consumed = pos
        }
        guard consumed > 0 else { return 0 }   // 只有半行，等写完

        var events: [UsageEvent] = []
        let base = data.startIndex
        for r in lines {
            if let e = p.consume(line: data[(base + r.lowerBound)..<(base + r.upperBound)], path: path) {
                events.append(e)
            }
        }
        let newOffset = offset + Int64(consumed)
        let cursor = Store.Cursor(path: path, agent: agent, offset: newOffset,
                                  fingerprint: Self.fingerprint(fh, end: newOffset), mtime: mtime,
                                  state: try? JSONEncoder().encode(p))
        try store.db.transaction {
            try store.upsert(events)
            try store.save(cursor)
        }
        return events.count
    }

    /// 游标前最多 64 字节的 FNV-1a 指纹。
    static func fingerprint(_ fh: FileHandle, end: Int64) -> UInt64 {
        let n = min(64, end)
        guard n > 0, (try? fh.seek(toOffset: UInt64(end - n))) != nil,
              let d = try? fh.read(upToCount: Int(n)) else { return 0 }
        var h: UInt64 = 0xcbf29ce484222325
        for b in d {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}
