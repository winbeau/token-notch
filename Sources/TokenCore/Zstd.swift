import Foundation

/// DeepSeek Harness 的会话文件是一串首尾相接、各自独立的 zstd 帧：每追加一批事件就追加一帧，
/// 最后一帧可能只写了一半。这里自己走帧头找出完整帧的边界（只读帧头和块头，不解压），
/// 再交给 zstd 命令行解压——macOS 自带的 Compression 框架不支持 zstd。
/// 实测每一帧都以换行结尾，所以字节游标停在帧边界上就等于停在行边界上。
enum Zstd {
    /// 本机的 zstd 可执行文件；找不到时 DeepSeek Harness 的日志跳过。
    static let executable: String? = {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/zstd" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// 完整帧（含跳过帧）一共多少字节。遇到不认识的魔数返回 nil（不是 zstd 文件）。
    static func completeFramesLength(_ data: Data) -> Int? {
        let b = [UInt8](data)
        func le(_ at: Int, _ n: Int) -> Int {
            var v = 0
            for k in 0..<n { v |= Int(b[at + k]) << (8 * k) }
            return v
        }
        var off = 0
        while off + 4 <= b.count {
            let magic = le(off, 4)
            if magic & 0xFFFF_FFF0 == 0x184D_2A50 {          // 跳过帧
                guard off + 8 <= b.count else { break }
                let end = off + 8 + le(off + 4, 4)
                guard end <= b.count else { break }
                off = end
                continue
            }
            guard magic == 0xFD2F_B528 else { return off == 0 ? nil : off }
            var p = off + 4
            guard p < b.count else { break }
            let fhd = Int(b[p])
            p += 1
            let single = (fhd >> 5) & 1, checksum = (fhd >> 2) & 1
            if single == 0 { p += 1 }                          // window descriptor
            p += [0, 1, 2, 4][fhd & 3]                         // dictionary id
            p += [single == 1 ? 1 : 0, 2, 4, 8][fhd >> 6]      // frame content size
            var complete = false
            while p + 3 <= b.count {
                let h = le(p, 3)
                p += 3
                p += (h >> 1) & 3 == 1 ? 1 : h >> 3           // RLE 块在盘上只有 1 字节
                if p > b.count { break }
                if h & 1 == 1 { complete = true; break }
            }
            guard complete else { break }
            if checksum == 1 { p += 4 }
            guard p <= b.count else { break }
            off = p
        }
        return off
    }

    /// 解压若干完整帧。zstd 不可用或失败时返回 nil。
    static func decompress(_ data: Data) -> Data? {
        guard let exe = executable else { return nil }
        // 输出写临时文件再一次读回：从管道逐块读几十 MB 很慢
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("token-notch-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["-dqf", "-o", tmp.path]
        let input = Pipe()
        proc.standardInput = input
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        // waitUntilExit 靠转 run loop 等退出通知，每次要多花约 0.1 秒；几百个文件时很明显，改用信号量
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return nil }
        // 写 stdin 放到后台，避免管道缓冲区满时和读 stdout 互相等待
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            try? writer.write(contentsOf: data)
            try? writer.close()
        }
        exited.wait()
        guard proc.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: tmp, options: .alwaysMapped)
    }
}
