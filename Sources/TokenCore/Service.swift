import CoreServices
import Foundation

/// FSEvents 文件级监听。回调在给定队列上执行。
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let queue: DispatchQueue
    private let handler: ([String]) -> Void

    public init(paths: [String], queue: DispatchQueue, handler: @escaping ([String]) -> Void) {
        self.paths = paths
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(eventPaths, to: NSArray.self)
            me.handler((0..<count).compactMap { arr[$0] as? String })
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}

/// 串起导入、监听和统计：启动时回填全部历史，之后按文件变动增量更新。
/// 所有数据库访问都在内部串行队列上；快照通过 `onSnapshot` 回调送出（在该队列上）。
public final class TokenService: @unchecked Sendable {
    public let store: Store
    public let ingestor: Ingestor
    public private(set) var engine: StatsEngine
    public var onSnapshot: ((Snapshot) -> Void)?
    public var onError: ((Error) -> Void)?
    /// 首次全量扫描是否已完成（在 onSnapshot 回调里读，同一队列）。
    public private(set) var ready = false

    private let queue = DispatchQueue(label: "token-notch.service", qos: .utility)
    private var watcher: FileWatcher?
    private var rescanTimer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?
    private var activity: [Agent: Date] = [:]
    private var lastPublish = Date.distantPast

    public init(store: Store, sources: [LogSource] = LogSource.defaults) {
        self.store = store
        ingestor = Ingestor(store: store, sources: sources)
        engine = StatsEngine(store: store)
    }

    public func start() {
        queue.async { [self] in
            // 首次回填可能要十几秒（DeepSeek Harness 的压缩日志），每扫完一类 agent 先发一份快照
            run { try ingestor.scanAll(afterSource: { [weak self] _ in self?.publish() }) }
            ready = true
            publish()
            startWatching()
            // 兜底：每分钟扫一遍（只读有变化的文件），也负责发现新建的日志目录。
            rescanTimer = timer(every: 60) { [weak self] in
                guard let self else { return }
                run { try self.ingestor.scanAll() }
                publish()
                if watcher == nil { startWatching() }
            }
            // 有 agent 在活动时每 2 秒刷新一次，让两翼和 tok/s 及时出现、及时消失。
            tickTimer = timer(every: 2) { [weak self] in
                guard let self else { return }
                if activity.values.contains(where: { Date().timeIntervalSince($0) < 120 }) { publish() }
            }
        }
    }

    public func stop() {
        queue.sync {
            watcher?.stop()
            watcher = nil
            rescanTimer?.cancel()
            tickTimer?.cancel()
        }
    }

    /// 清空数据库并重新回填。
    public func rebuild() {
        queue.async { [self] in
            run {
                try store.reset()
                try ingestor.scanAll()
            }
            publish()
        }
    }

    public func reloadPricing() {
        queue.async { [self] in
            engine.pricing = .load()
            publish()
        }
    }

    private func startWatching() {
        let roots = ingestor.sources.flatMap(\.roots).map(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        let w = FileWatcher(paths: roots, queue: queue) { [weak self] paths in
            self?.handleChanges(paths)
        }
        w.start()
        watcher = w
    }

    private func handleChanges(_ paths: [String]) {
        let now = Date()
        for p in paths {
            if let a = ingestor.agent(for: p) { activity[a] = now }
        }
        run { try ingestor.ingest(paths: paths) }
        publish()
    }

    private func publish() {
        do {
            let snap = try engine.snapshot(activity: activity)
            lastPublish = Date()
            onSnapshot?(snap)
        } catch {
            onError?(error)
        }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { onError?(error) }
    }

    private func timer(every seconds: Double, _ body: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(200))
        t.setEventHandler(handler: body)
        t.resume()
        return t
    }
}
