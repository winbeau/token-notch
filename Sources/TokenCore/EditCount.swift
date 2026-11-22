import Foundation

/// 一次代码编辑的行数。
///
/// 规则：每处改动记 max(新增, 删除) 行——改一行（+1−1）记 1 行，+7−5 和 +5−7 都记 7 行。
/// 一次工具调用里有多处改动（MultiEdit 的多段、补丁的多个 hunk）时逐处取 max 再相加。
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

    /// 字符串替换（Claude 的 Edit、Antigravity 的 edit_file、DSH 的 edit）：按行做 diff，
    /// 每段连续的增删是一处改动。先去掉首尾相同的行；中间部分不太大时用 LCS 找出未改动的行，
    /// 太大（超过 400 万格）就把中间整体当成一处改动。
    public static func replace(old: String, new: String) -> EditChange {
        let a = lines(old), b = lines(new)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        var j = 0
        while j < a.count - i, j < b.count - i, a[a.count - 1 - j] == b[b.count - 1 - j] { j += 1 }
        let x = Array(a[i..<(a.count - j)]), y = Array(b[i..<(b.count - j)])
        if x.isEmpty || y.isEmpty || x.count * y.count > 4_000_000 {
            return .block(added: y.count, removed: x.count)
        }
        return diffBlocks(x, y)
    }

    /// LCS 回溯，按连续的增删分段求和。
    static func diffBlocks(_ x: [Substring], _ y: [Substring]) -> EditChange {
        let n = x.count, m = y.count, w = m + 1
        // lcs[i][j]：x[i...] 与 y[j...] 的最长公共子序列长度
        var lcs = [Int32](repeating: 0, count: (n + 1) * w)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * w + j] = x[i] == y[j] ? lcs[(i + 1) * w + j + 1] + 1
                    : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
            }
        }
        var total = EditChange()
        var plus = 0, minus = 0, i = 0, j = 0
        func flush() {
            if plus > 0 || minus > 0 { total += .block(added: plus, removed: minus) }
            plus = 0
            minus = 0
        }
        while i < n || j < m {
            if i < n, j < m, x[i] == y[j] {
                flush()
                i += 1
                j += 1
            } else if j < m, i == n || lcs[i * w + j + 1] >= lcs[(i + 1) * w + j] {
                plus += 1
                j += 1
            } else {
                minus += 1
                i += 1
            }
        }
        flush()
        return total
    }

    /// 整个写入文件：全部算新增。
    public static func write(_ content: String) -> EditChange {
        .block(added: lines(content).count, removed: 0)
    }

    /// apply_patch 格式（`*** Begin Patch` … `*** End Patch`）。每段连续的 +/− 行是一处改动；
    /// 上下文行、`@@`、`*** Update File:` 之类的标记都会把改动分开。
    public static func patch(_ text: String) -> EditChange {
        var total = EditChange()
        var plus = 0, minus = 0
        func flush() {
            if plus > 0 || minus > 0 { total += .block(added: plus, removed: minus) }
            plus = 0
            minus = 0
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("***") || line.hasPrefix("@@") {
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
