import Foundation

/// 日志目录下哪些文件算日志。
public enum FileMatch: Sendable {
    case jsonl                  // 任意 *.jsonl
    case named(String)          // 固定文件名（目录里还有别的 jsonl）
    case dshSession             // session.v<N>.jsonl[.zstd]

    public func accepts(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        switch self {
        case .jsonl: return name.hasSuffix(".jsonl")
        case .named(let n): return name == n
        case .dshSession:
            return name.hasPrefix("session.v") && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zstd"))
        }
    }
}

/// 一类 agent 的日志位置。
public struct LogSource: Sendable {
    public var agent: Agent
    public var roots: [URL]
    public var match: FileMatch

    public init(agent: Agent, roots: [URL], match: FileMatch = .jsonl) {
        self.agent = agent
        self.roots = roots
        self.match = match
    }

    public static var defaults: [LogSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dsh = env["DSH_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".dsh")
        return [
            LogSource(agent: .claude, roots: [home.appendingPathComponent(".claude/projects")]),
            LogSource(agent: .codex, roots: [home.appendingPathComponent(".codex/sessions"),
                                             home.appendingPathComponent(".codex/archived_sessions")]),
            // IDE 写 antigravity/，CLI 写 antigravity-cli/，布局相同
            LogSource(agent: .antigravity, roots: [home.appendingPathComponent(".gemini/antigravity/brain"),
                                                   home.appendingPathComponent(".gemini/antigravity-cli/brain")],
                      match: .named("transcript_full.jsonl")),
            LogSource(agent: .grok, roots: [home.appendingPathComponent(".grok/sessions"),
                                            home.appendingPathComponent(".grok/archived_sessions")],
                      match: .named("updates.jsonl")),
            LogSource(agent: .deepseek, roots: [dsh.appendingPathComponent("sessions")], match: .dshSession),
        ]
    }
}

public struct IngestResult: Sendable {
    public var filesRead = 0
    public var events = 0
    public var edits = 0
    public var images = 0
    public var touchedAgents: Set<Agent> = []

    mutating func add(_ n: (events: Int, edits: Int, images: Int), agent: Agent) {
        filesRead += 1
        events += n.events
        edits += n.edits
        images += n.images
        if n.events + n.edits + n.images > 0 { touchedAgents.insert(agent) }
    }
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
            LogSource(agent: $0.agent, roots: $0.roots.map { URL(fileURLWithPath: Self.canonical($0.path)) }, match: $0.match)
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
    /// `afterSource`：每扫完一类 agent 回调一次（首次回填时让界面先显示已导入的部分）。
    @discardableResult
    public func scanAll(afterSource: ((Agent) -> Void)? = nil) throws -> IngestResult {
        let cursors = try store.allCursors()
        var result = IngestResult()
        for source in sources {
            for path in Self.files(under: source.roots, match: source.match) {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if let c = cursors[path], c.offset == size, c.mtime == mtime { continue }
                result.add(try ingestFile(path, agent: source.agent), agent: source.agent)
            }
            afterSource?(source.agent)
        }
        return result
    }

    /// 只处理给定路径（文件监听回调用）。不属于任何来源的路径忽略。
    @discardableResult
    public func ingest(paths: [String]) throws -> IngestResult {
        var result = IngestResult()
        for path in Set(paths.map(Self.canonical)) {
            guard let source = source(for: path), source.match.accepts(path),
                  FileManager.default.fileExists(atPath: path) else { continue }
            let agent = source.agent
            result.add(try ingestFile(path, agent: agent), agent: agent)
        }
        return result
    }

    public func agent(for path: String) -> Agent? {
        source(for: path)?.agent
    }

    func source(for path: String) -> LogSource? {
        let path = Self.canonical(path)
        return sources.first { s in s.roots.contains(where: { path.hasPrefix($0.path + "/") }) }
    }

    static func files(under roots: [URL], match: FileMatch) -> [String] {
        var out: [String] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where match.accepts(url.path) {
                out.append(url.path)
            }
        }
        return out
    }

    func ingestFile(_ path: String, agent: Agent) throws -> (events: Int, edits: Int, images: Int) {
        switch agent {
        case .claude: return try ingest(path, agent: agent, parser: ClaudeParser.self)
        case .codex: return try ingest(path, agent: agent, parser: CodexParser.self)
        case .antigravity: return try ingest(path, agent: agent, parser: AntigravityParser.self)
        case .grok: return try ingest(path, agent: agent, parser: GrokParser.self)
        case .deepseek: return try ingest(path, agent: agent, parser: DeepSeekParser.self)
        }
    }

    private func ingest<P: LogParser>(_ path: String, agent: Agent, parser: P.Type) throws -> (events: Int, edits: Int, images: Int) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return (0, 0, 0) }
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
            return (0, 0, 0)
        }

        try fh.seek(toOffset: UInt64(offset))
        var data = try fh.readToEnd() ?? Data()
        // zstd 压缩的日志（DeepSeek Harness）：只取完整帧解压；游标按压缩字节前进
        var compressedConsumed: Int?
        if path.hasSuffix(".zstd") {
            guard let n = Zstd.completeFramesLength(data), n > 0,
                  let plain = Zstd.decompress(data.prefix(n)) else { return (0, 0, 0) }
            compressedConsumed = n
            data = plain
        }
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
        guard consumed > 0 else { return (0, 0, 0) }   // 只有半行，等写完

        var out = ParseOutput()
        let base = data.startIndex
        for r in lines {
            p.consume(line: data[(base + r.lowerBound)..<(base + r.upperBound)], path: path, into: &out)
        }
        P.enrich(&out, path: path)
        let newOffset = offset + Int64(compressedConsumed ?? consumed)
        let cursor = Store.Cursor(path: path, agent: agent, offset: newOffset,
                                  fingerprint: Self.fingerprint(fh, end: newOffset), mtime: mtime,
                                  state: try? JSONEncoder().encode(p))
        try store.db.transaction {
            try store.upsert(out.events)
            try store.upsert(edits: out.edits)
            try store.upsert(images: out.images)
            try store.save(cursor)
        }
        return (out.events.count, out.edits.count, out.images.count)
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
