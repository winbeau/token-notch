import Foundation

/// 一次生图调用。本机生图走 `img`（Codex 的 image-relay）或 `imagegen`（Claude Code 的技能）命令，
/// agent 通过 shell 工具调用它；内置的 image_gen 工具在本机中转下是关闭的，出现时也照样计数。
public struct ImageEvent: Sendable, Equatable {
    public var key: String
    public var agent: Agent
    public var ts: Int64
    public var cwd: String
    public var session: String
    public var kind: String        // generate / edit / builtin
    public var model: String
    public var count: Int64        // 张数（--n）

    public init(key: String, agent: Agent, ts: Int64, cwd: String, session: String,
                kind: String, model: String, count: Int64) {
        self.key = key
        self.agent = agent
        self.ts = ts
        self.cwd = cwd
        self.session = session
        self.kind = kind
        self.model = model
        self.count = count
    }
}

public enum ImageCalls {
    /// 两个命令的默认模型（见 ~/.codex/skills/image-relay/SKILL.md 与 imagegen 脚本）。
    public static let defaultModel = "gpt-image-2.5-sunburst"

    public struct Call: Equatable {
        public var kind: String
        public var model: String
        public var count: Int64
    }

    /// 命令位置上的 `img|imagegen generate|edit`（前面是行首、空白、分隔符、引号或路径）。
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:^|[\s;&|(`'"])(?:[\w./~-]*/)?(img|imagegen)\s+(generate|edit)\b"#)
    private static let modelFlag = try! NSRegularExpression(pattern: #"--model[\s=]+['"]?([\w.\-]+)"#)
    /// 紧挨在命令前的环境变量：`IMAGE_RELAY_MODEL=gpt-image-2 img …`
    private static let modelEnv = try! NSRegularExpression(pattern: #"_MODEL=['"]?([\w.\-]+)['"]?\s+(?:[\w./~-]*/)?$"#)
    private static let helpFlag = try! NSRegularExpression(pattern: #"\s(?:-h|--help|--dry-run)(?:\s|$|['"])"#)
    private static let nFlag = try! NSRegularExpression(pattern: #"--n[\s=]+(\d+)"#)

    /// 快速预筛：行里没有这些字样就不用解析。
    static let markers = ["img generate", "img edit", "imagegen generate", "imagegen edit", "image_gen"].map(bytes)

    /// 从一段命令文本里找出生图调用。`--help`、`--dry-run` 不花额度，不算。
    public static func find(in text: String) -> [Call] {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [Call] = []
        for (i, m) in matches.enumerated() {
            // 这次调用的参数：到下一处调用、换行、命令分隔符或 JS 字符串结束为止
            let start = m.range.location
            let limit = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            var seg = ns.substring(with: NSRange(location: start, length: limit - start))
            if let cut = seg.rangeOfCharacter(from: CharacterSet(charactersIn: "\n;`")) { seg = String(seg[..<cut.lowerBound]) }
            if let cut = seg.range(of: "&&") { seg = String(seg[..<cut.lowerBound]) }
            let segNS = seg as NSString
            let segRange = NSRange(location: 0, length: segNS.length)
            if helpFlag.firstMatch(in: seg, range: segRange) != nil { continue }
            // 匹配到的前导字符（空白、引号等）之后才是命令本身
            let prefix = String(ns.substring(to: start + 1).suffix(80))
            let pn = prefix as NSString
            let model = modelFlag.firstMatch(in: seg, range: segRange).map { segNS.substring(with: $0.range(at: 1)) }
                ?? modelEnv.firstMatch(in: prefix, range: NSRange(location: 0, length: pn.length))
                    .map { pn.substring(with: $0.range(at: 1)) }
                ?? defaultModel
            let n = nFlag.firstMatch(in: seg, range: segRange)
                .flatMap { Int64(segNS.substring(with: $0.range(at: 1))) } ?? 1
            out.append(Call(kind: ns.substring(with: m.range(at: 2)), model: model, count: max(1, n)))
        }
        return out
    }

    /// 把一段命令文本里的调用转成事件，键 = 前缀 + 序号。
    static func events(in text: String, keyPrefix: String, agent: Agent, ts: Int64,
                       cwd: String, session: String) -> [ImageEvent] {
        find(in: text).enumerated().map { i, c in
            ImageEvent(key: "\(keyPrefix):img\(i)", agent: agent, ts: ts, cwd: cwd, session: session,
                       kind: c.kind, model: c.model, count: c.count)
        }
    }
}
