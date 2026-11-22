import Foundation

/// 极简 protobuf 读取：只按字段号取值，不需要 .proto。用于读 Antigravity 原生库里的模型名和耗时。
enum Proto {
    enum Value {
        case varint(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed
    }

    /// 解析一层字段；遇到坏数据就停在那里，返回已经读到的部分。
    static func fields(_ b: ArraySlice<UInt8>) -> [(Int, Value)] {
        var out: [(Int, Value)] = []
        var i = b.startIndex
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.endIndex, shift < 64 {
                let c = b[i]
                i += 1
                v |= UInt64(c & 0x7F) << shift
                if c & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.endIndex {
            guard let key = varint() else { break }
            let num = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint() else { return out }
                out.append((num, .varint(v)))
            case 1:
                guard b.endIndex - i >= 8 else { return out }
                i += 8
                out.append((num, .fixed))
            case 2:
                guard let n = varint(), n <= UInt64(b.endIndex - i) else { return out }
                out.append((num, .bytes(b[i..<(i + Int(n))])))
                i += Int(n)
            case 5:
                guard b.endIndex - i >= 4 else { return out }
                i += 4
                out.append((num, .fixed))
            default:
                return out
            }
        }
        return out
    }

    static func message(_ b: ArraySlice<UInt8>, _ num: Int) -> ArraySlice<UInt8>? {
        for (n, v) in fields(b) where n == num { if case .bytes(let d) = v { return d } }
        return nil
    }

    static func string(_ b: ArraySlice<UInt8>, _ num: Int) -> String? {
        message(b, num).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    static func varint(_ b: ArraySlice<UInt8>, _ num: Int) -> UInt64? {
        for (n, v) in fields(b) where n == num { if case .varint(let x) = v { return x } }
        return nil
    }

    /// google.protobuf.Duration → 毫秒。
    static func durationMs(_ b: ArraySlice<UInt8>) -> Int64 {
        Int64(varint(b, 1) ?? 0) * 1000 + Int64(varint(b, 2) ?? 0) / 1_000_000
    }
}
