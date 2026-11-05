import Foundation

/// 按 edge-tts 的 Sec-MS-GEC v2 算法生成请求令牌，输入为带时钟校准的 Unix 时间。
enum EdgeTTSGEC {
    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let windowsEpoch: TimeInterval = 11_644_473_600
    static let chromiumVersion = "143.0.3650.75"
    static var chromiumMajor: String { String(chromiumVersion.prefix { $0 != "." }) }
    static var secMSGECVersion: String { "2-\(chromiumVersion)" }

    /// 将 Unix 时间对齐到 5 分钟窗口后计算 CS64 与自定义 SHA-256 组合令牌。
    static func token(unixTimestamp: TimeInterval) -> String {
        var ticks = unixTimestamp + windowsEpoch
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        ticks *= 1e9 / 100
        let payload = Data((String(format: "%.0f", ticks) + trustedClientToken).utf8)
        let digest = sha256(payload)
        let cs64 = cs64Digest(payload, digest: digest)
        return hex(u32LE(cs64.0) + u32LE(cs64.1)) + "-" + hex(digest)
    }

    /// 解析 HTTP Date，供 403 时钟校准使用。
    static func parseHTTPDate(_ value: String) -> TimeInterval? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)?.timeIntervalSince1970
    }

    private static let sha256Initial: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]
    private static let sha256State: [UInt32] = [
        0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, 0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2
    ]
    private static let sha256Schedule: [UInt32] = [
        0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, 0xA622EE8C, 0xD1DD9491, 0xC0DD25A0,
        0xF9E70AB6, 0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33, 0xD258B060, 0x72766564
    ]
    private static let sha256Round: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
    ]
    private static let sha256Adjustment: UInt32 = 0xC9DC06A7
    private static var sha256Block: [UInt32] {
        var values = sha256Round
        values[14] = sha256Adjustment
        return values
    }
    private static let sigma0Adjustment: UInt32 = 0x059C0B80
    private static let sigma1Adjustment: UInt32 = 0x000B92C0
    private static let cs64Coefficients: [(UInt32, UInt32)] = [
        (0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D), (0x3BEB65BC, 0x29514038), (0xC89C5933, 0xB328CBDF),
        (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C), (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB),
        (0x06064CF3, 0xFA51A3DA), (0xDA79FA60, 0x207CC464), (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61),
        (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167)
    ]
    private static let cs64Factor: UInt32 = 0x82893933
    private static let cs64Adjustment0: UInt32 = 0xF2F90B1A
    private static let cs64Adjustment1: UInt32 = 0x0B1A0000

    /// 对令牌字节做 edge-tts 的自定义 SHA-256，前 7 字节走预计算状态。
    private static func sha256(_ data: Data) -> Data {
        let length = 57 + data.count
        var padded = Data(data.dropFirst(7))
        padded.append(0x80)
        let zeros = ((55 - length) % 64 + 64) % 64
        padded.append(contentsOf: repeatElement(UInt8(0), count: zeros))
        var bitLength = UInt64(length * 8).bigEndian
        padded.append(Data(bytes: &bitLength, count: 8))
        var state = sha256Init(Data(data.prefix(7)))
        var offset = 0
        while offset < padded.count {
            var words: [UInt32] = (0..<16).map { readBE(padded, offset + $0 * 4) }
            expandSchedule(&words, from: 16)
            let working = rounds(state: state, words: words, firstRound: 0, constants: sha256Round)
            state = zip(state, working).map { $0 &+ $1 }
            offset += 64
        }
        var output = Data()
        for word in state {
            var big = word.bigEndian
            output.append(Data(bytes: &big, count: 4))
        }
        return output
    }

    /// 用前 7 个字节恢复 SHA-256 中间状态，对应 token 盐的固定前缀处理。
    private static func sha256Init(_ data: Data) -> [UInt32] {
        var words = Array(repeating: UInt32(0), count: 14)
        words.append((UInt32(data[0]) << 16) | (UInt32(data[1]) << 8) | UInt32(data[2]))
        words.append(readBE(data, 3))
        for index in 16..<30 {
            var value = UInt64(sha256Schedule[index - 16])
            if index - 2 >= 14 {
                let sigma = UInt64(sigma1(words[index - 2]))
                value &+= index == 16 ? (sigma ^ UInt64(sigma1Adjustment)) : sigma
            }
            if index - 7 >= 14 { value &+= UInt64(words[index - 7]) }
            if index - 15 >= 14 {
                let sigma = UInt64(sigma0(words[index - 15]))
                value &+= index == 29 ? (sigma ^ UInt64(sigma0Adjustment)) : sigma
            }
            words.append(UInt32(truncatingIfNeeded: value))
        }
        let extra = Int64(sigma1(words[28])) + Int64(words[23]) + Int64(sigma0(words[15])) + Int64(words[14])
            + Int64(sha256Adjustment) - Int64(sha256Round[14])
        words.append(UInt32(truncatingIfNeeded: extra))
        expandSchedule(&words, from: 31)
        let working = rounds(state: sha256State, words: words, firstRound: 14, constants: sha256Block)
        return zip(sha256Initial, working).map { $0 &+ $1 }
    }

    /// 从指定轮次继续 SHA-256 压缩，403 令牌使用修改过的第 14 轮常量。
    private static func rounds(state: [UInt32], words: [UInt32], firstRound: Int, constants: [UInt32]) -> [UInt32] {
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for index in firstRound..<64 {
            let rotE = UInt64(e) &* 0x1_0000_0001
            let rotA = UInt64(a) &* 0x1_0000_0001
            let t1 = UInt64(h) &+ ((rotE >> 6) ^ (rotE >> 11) ^ (rotE >> 25))
                &+ UInt64(g ^ (e & (f ^ g))) &+ UInt64(constants[index]) &+ UInt64(words[index])
            let t2 = ((rotA >> 2) ^ (rotA >> 13) ^ (rotA >> 22)) &+ UInt64((a & b) | (c & (a | b)))
            h = g; g = f; f = e
            e = UInt32(truncatingIfNeeded: UInt64(d) &+ t1)
            d = c; c = b; b = a
            a = UInt32(truncatingIfNeeded: t1 &+ t2)
        }
        return [a, b, c, d, e, f, g, h]
    }

    /// 按 SHA-256 消息扩展公式补齐 64 个字，左移在 64 位上完成后再截断。
    private static func expandSchedule(_ words: inout [UInt32], from firstWord: Int) {
        for index in firstWord..<64 {
            let x = UInt64(words[index - 2])
            let y = UInt64(words[index - 15])
            let s1 = (x >> 17) ^ (x << 15) ^ (x >> 19) ^ (x << 13) ^ (x >> 10)
            let s0 = (y >> 7) ^ (y << 25) ^ (y >> 18) ^ (y << 14) ^ (y >> 3)
            words.append(UInt32(truncatingIfNeeded: s1 &+ UInt64(words[index - 7]) &+ s0 &+ UInt64(words[index - 16])))
        }
    }

    /// 计算令牌中的 CS64 摘要，结果按小端 32 位字拼接。
    private static func cs64Digest(_ data: Data, digest: Data) -> (UInt32, UInt32) {
        let keyA = readLE(digest, 0) | 1
        let keyB = readLE(digest, 4) | 1
        let factors: [UInt32] = [keyA &* cs64Factor, keyB &* cs64Factor]
        var terms: [UInt32] = cs64Coefficients.enumerated().map { index, item in
            item.0 &* factors[index % 2]
        }
        var offsets: [UInt32] = cs64Coefficients.map(\.1)
        for (index, word) in wordsLE4Even(Data([0]) + data).enumerated() {
            var term = UInt64(word) &* UInt64(index % 2 == 0 ? keyA : keyB)
            var offset = UInt64(rol16(word)) &* UInt64(index % 2 == 0 ? 0xEF0569FB : 0xC31713DB)
            if index == 0 {
                term &+= UInt64(cs64Adjustment0) &* UInt64(factors[0])
                offset &+= UInt64(cs64Adjustment1)
            }
            terms.append(UInt32(truncatingIfNeeded: term))
            offsets.append(UInt32(truncatingIfNeeded: offset))
        }
        var swapAcc: UInt64 = 0
        var swapLast: UInt32 = 0
        var state: UInt32 = 0
        var acc: UInt64 = 0
        for index in stride(from: 0, to: terms.count, by: 2) {
            let x = terms[index]
            let y = terms[index + 1]
            var t = rol16(offsets[index] &+ x)
            var q = t &* 0x76F50F34
            swapAcc &+= UInt64(rol16(q) &* 0xC3EFEA97 &+ q)
            t = rol16(offsets[index + 1] &+ y)
            q = t &* 0x1881CE3C
            swapLast = rol16(q) &* 0x35BD1EC9 &+ q
            swapAcc = (swapAcc &+ UInt64(swapLast)) & 0xFFFF_FFFF
            state = state &* keyA &+ x
            state = rol16(state) &* 0xCF98B111
            state = rol16(state) &* 0x87085B9F
            state = rol16(state) &* 0x12CEB96D
            state = rol16(state) &* 0x257E1D83
            acc &+= UInt64(state)
            var mixed = UInt64(state) &* UInt64(keyB) &+ UInt64(y)
            mixed = UInt64(rol16(UInt32(truncatingIfNeeded: mixed))) &* 0xA27416F5
            mixed = UInt64(rol16(UInt32(truncatingIfNeeded: mixed))) &* 0xD38396FF
            let rotated = rol16(UInt32(truncatingIfNeeded: mixed)) &* 0x7C932B89
            state = rol16(rotated) &* 0xBFA49F69
            acc = (acc &+ UInt64(state)) & 0xFFFF_FFFF
        }
        return (swapLast ^ state, UInt32(truncatingIfNeeded: swapAcc) ^ UInt32(truncatingIfNeeded: acc))
    }

    /// 把数据补齐为偶数个小端 32 位字，供 CS64 按双字处理。
    private static func wordsLE4Even(_ data: Data) -> [UInt32] {
        let pad = (4 - (data.count % 4)) % 4
        var padded = data
        if pad > 0 { padded.append(contentsOf: repeatElement(UInt8(0), count: pad)) }
        var words: [UInt32] = []
        var offset = 0
        while offset < padded.count {
            words.append(readLE(padded, offset))
            offset += 4
        }
        if words.count % 2 == 1 { words.append(0) }
        return words
    }

    private static func sigma0(_ value: UInt32) -> UInt32 {
        let v = UInt64(value)
        return UInt32(truncatingIfNeeded: (v >> 7) ^ (v << 25) ^ (v >> 18) ^ (v << 14) ^ (v >> 3))
    }

    private static func sigma1(_ value: UInt32) -> UInt32 {
        let v = UInt64(value)
        return UInt32(truncatingIfNeeded: (v >> 17) ^ (v << 15) ^ (v >> 19) ^ (v << 13) ^ (v >> 10))
    }

    private static func rol16(_ value: UInt32) -> UInt32 { (value << 16) | (value >> 16) }
    private static func readBE(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
    private static func readLE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
    private static func u32LE(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: 4)
    }
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

/// 跨音色列表和合成请求共享时钟偏移，403 时按服务端 Date 累加校准。
public final class EdgeTTSClock: @unchecked Sendable {
    public static let shared = EdgeTTSClock()
    private let lock = NSLock()
    private var skewSeconds: TimeInterval = 0
    private let now: @Sendable () -> TimeInterval

    /// 测试可注入固定当前时间，正式听书使用系统 UTC 时间。
    public init(now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    /// 返回已校准的 Unix 时间，令牌窗口依赖该值。
    public func unixTimestamp() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return now() + skewSeconds
    }

    /// 用 403 响应的 Date 调整偏移，缺少或无法解析时按协议报错。
    public func handleForbidden(headers: [String: String]) throws {
        guard let date = headers.first(where: { $0.key.caseInsensitiveCompare("Date") == .orderedSame })?.value else {
            throw EdgeTTSError.missingServerDate
        }
        guard let server = EdgeTTSGEC.parseHTTPDate(date) else {
            throw EdgeTTSError.invalidServerDate(date)
        }
        let client = unixTimestamp()
        lock.lock()
        skewSeconds += server - client
        lock.unlock()
    }
}
