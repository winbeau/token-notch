import Foundation

/// 一次代码编辑的行数。
///
/// 规则：每处改动记 max(新增, 删除) 行——改一行（+1−1）记 1 行，+7−5 和 +5−7 都记 7 行。
/// 一次工具调用里有多处改动（MultiEdit 的多段、补丁的多个 hunk）时逐处取 max 再相加。
/// 覆盖已有文件时对上一版做 diff，不把整个文件算成新增；临时目录、agent 自己的工作目录、
/// 锁文件和生成物不计入（见 `EditCount.isCounted`）。
public struct EditChange: Codable, Equatable, Sendable {
    public var added: Int64 = 0
    public var removed: Int64 = 0
    public var lines: Int64 = 0

    public init(added: Int64 = 0, removed: Int64 = 0, lines: Int64 = 0) {
        self.added = added
        self.removed = removed
        self.lines = lines
    }

    /// 单处改动：lines = max(added, removed)。
    public static func block(added: Int, removed: Int) -> EditChange {
        EditChange(added: Int64(added), removed: Int64(removed), lines: Int64(max(added, removed)))
    }

    public var isEmpty: Bool { added == 0 && removed == 0 }

    public static func + (a: EditChange, b: EditChange) -> EditChange {
        EditChange(added: a.added + b.added, removed: a.removed + b.removed, lines: a.lines + b.lines)
    }

    public static func += (a: inout EditChange, b: EditChange) { a = a + b }
}

public enum EditCount {
    /// 按 `\n` 切行；末尾换行不算多一行，空串是 0 行。
    static func lines(_ s: String) -> [Substring] {
        guard !s.isEmpty else { return [] }
        var parts = s.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// 每行一个 32 位哈希（FNV-1a）。diff 只比较哈希；解析器要跨批次记住文件内容时也只存它。
    /// 不用 Swift 自带的 Hasher：那个每次进程启动种子都不同，存下来的状态下次就对不上了。
    static func hashes(_ s: String) -> [UInt32] { lines(s).map(hash) }

    static func hash<S: StringProtocol>(_ line: S) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in line.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }

    /// 两个版本之间的改动（Claude 的 Edit、Antigravity 的 edit_file、DSH 的 edit，以及覆盖写入时的新旧全文）：
    /// 按行做 diff，每段连续的增删是一处改动。
    public static func replace(old: String, new: String) -> EditChange {
        diff(hashes(old), hashes(new))
    }

    /// 先去掉首尾相同的行，中间部分用标准库的 Myers diff；中间实在太大（超过 3600 万格）就整体当成一处改动。
    static func diff(_ a: [UInt32], _ b: [UInt32]) -> EditChange {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        var j = 0
        while j < a.count - i, j < b.count - i, a[a.count - 1 - j] == b[b.count - 1 - j] { j += 1 }
        let x = Array(a[i..<(a.count - j)]), y = Array(b[i..<(b.count - j)])
        if x.isEmpty || y.isEmpty || x.count * y.count > 36_000_000 {
            return .block(added: y.count, removed: x.count)
        }
        var removed = [Bool](repeating: false, count: x.count), inserted = [Bool](repeating: false, count: y.count)
        for change in y.difference(from: x) {
            switch change {
            case .remove(let offset, _, _): removed[offset] = true
            case .insert(let offset, _, _): inserted[offset] = true
            }
        }
        // 两边同步往前走：没被删、没被加的行是对上的，它把前后的改动分成两处
        var total = EditChange()
        var plus = 0, minus = 0, p = 0, q = 0
        while p < x.count || q < y.count {
            if p < x.count, removed[p] {
                minus += 1
                p += 1
            } else if q < y.count, inserted[q] {
                plus += 1
                q += 1
            } else {
                if plus > 0 || minus > 0 { total += .block(added: plus, removed: minus) }
                plus = 0
                minus = 0
                p += 1
                q += 1
            }
        }
        if plus > 0 || minus > 0 { total += .block(added: plus, removed: minus) }
        return total
    }

    /// 新建文件：全部算新增。覆盖已有文件不走这里，要拿上一版做 diff（见各解析器）。
    public static func write(_ content: String) -> EditChange {
        // 只数换行，不切分（写入的整个文件可能很大）
        let u = content.utf8
        guard !u.isEmpty else { return EditChange() }
        let n = u.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } + (u.last == 0x0A ? 0 : 1)
        return .block(added: n, removed: 0)
    }

    /// 一段带前缀的 diff 行（`+` 新增、`-` 删除、其余是上下文）：每段连续的 +/− 是一处改动。
    /// Claude Code 工具结果里的 structuredPatch 就是这种格式。
    public static func hunk(_ lines: [String]) -> EditChange {
        var total = EditChange()
        var plus = 0, minus = 0
        func flush() {
            if plus > 0 || minus > 0 { total += .block(added: plus, removed: minus) }
            plus = 0
            minus = 0
        }
        for line in lines {
            if line.hasPrefix("+") {
                plus += 1
            } else if line.hasPrefix("-") {
                minus += 1
            } else {
                flush()
            }
        }
        flush()
        return total
    }

    /// apply_patch 格式（`*** Begin Patch` … `*** End Patch`）。每段连续的 +/− 行是一处改动；
    /// 上下文行、`@@`、`*** Update File:` 之类的标记都会把改动分开。
    /// `counts` 按文件决定算不算（`*** Add File:` / `*** Update File:` 后面的路径），默认都算。
    public static func patch(_ text: String, counts: (String) -> Bool = { _ in true }) -> EditChange {
        var total = EditChange()
        var plus = 0, minus = 0, counting = true
        func flush() {
            if counting, plus > 0 || minus > 0 { total += .block(added: plus, removed: minus) }
            plus = 0
            minus = 0
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("***") {
                flush()
                if let r = line.range(of: " File: ") {
                    counting = counts(line[r.upperBound...].trimmingCharacters(in: .whitespaces))
                }
            } else if line.hasPrefix("@@") {
                flush()
            } else if line.hasPrefix("+") {
                plus += 1
            } else if line.hasPrefix("-") {
                minus += 1
            } else {
                flush()
            }
        }
        flush()
        return total
    }

    // MARK: 哪些文件不算

    /// 临时目录
    static let scratchPrefixes = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
    /// 各 agent 自己的工作目录（在用户主目录下）：计划、记忆、草稿、会话数据
    static let agentHomes = [".claude", ".codex", ".gemini", ".dsh", ".grok"]
    /// 锁文件
    static let lockFiles: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "cargo.lock", "poetry.lock", "uv.lock",
        "package.resolved", "go.sum", "gemfile.lock", "composer.lock", "podfile.lock",
    ]
    /// 依赖和构建产物目录
    static let generatedDirs: Set<String> = ["node_modules", ".build", "__pycache__", ".venv", "Pods", "DerivedData", ".git"]

    /// 这个文件的编辑算不算进行数。不算的有三类：临时目录里的、agent 自己工作目录里的、锁文件和生成物。
    /// 相对路径先接到 `cwd` 上再判断。
    public static func isCounted(path: String, cwd: String = "", home: String = NSHomeDirectory()) -> Bool {
        guard !path.isEmpty else { return true }
        var full = path
        if full.hasPrefix("~/") {
            full = home + full.dropFirst(1)
        } else if !full.hasPrefix("/"), !cwd.isEmpty {
            full = cwd + (cwd.hasSuffix("/") ? "" : "/") + full
        }
        if scratchPrefixes.contains(where: full.hasPrefix) { return false }
        if agentHomes.contains(where: { full.hasPrefix(home + "/" + $0 + "/") }) { return false }
        let parts = full.split(separator: "/")
        guard let name = parts.last?.lowercased() else { return true }
        if lockFiles.contains(name) || name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".map") {
            return false
        }
        return !parts.dropLast().contains { generatedDirs.contains(String($0)) }
    }

    /// 从任意文本里找出所有 `*** Begin Patch` … `*** End Patch` 补丁。Codex 新版把 apply_patch
    /// 包在 exec 的 JS 代码里（模板字符串，或带 `\n` 转义的普通字符串），这里统一还原成真换行。
    public static func patches(in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let start = rest.range(of: "*** Begin Patch") {
            let after = rest[start.upperBound...]
            let end = after.range(of: "*** End Patch")
            var body = String(after[..<(end?.lowerBound ?? after.endIndex)])
            let escapedNewlines = body.components(separatedBy: "\\n").count - 1
            let realNewlines = body.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            if escapedNewlines > realNewlines { body = unescape(body) }
            out.append(body)
            rest = end.map { after[$0.upperBound...] } ?? after[after.endIndex...]
        }
        return out
    }

    /// JS / JSON 字符串字面量里常见的转义。
    static func unescape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else {
                out.append(c)
                continue
            }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": break
            default: out.append(n)   // \" \' \\ \` 等
            }
        }
        return out
    }
}
