import Foundation

/// 音频中的文字边界保留服务端时间及原文 UTF-16 范围，供播放器准确定位正文。
public struct HttpTTSSpeechBoundary: Codable, Equatable, Sendable {
    public let offsetTicks: Int64
    public let range: NSRange

    /// 使用微软协议的 100 纳秒时间单位，避免跨块累计时引入浮点误差。
    public init(offsetTicks: Int64, range: NSRange) {
        self.offsetTicks = offsetTicks
        self.range = range
    }

    /// 二分查找播放器已经播放到的最后一个文字边界，不按字数估算时间。
    public static func position(at time: TimeInterval, in boundaries: [Self]) -> Int? {
        let ticks = Int64(time * 10_000_000)
        var lower = 0
        var upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if boundaries[middle].offsetTicks <= ticks {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == 0 ? nil : boundaries[lower - 1].range.location
    }
}

/// Edge 合成错误保留请求状态或协议原因，由听书界面直接显示。
public enum EdgeTTSError: Error, LocalizedError, Equatable, Sendable {
    case http(status: Int, headers: [String: String], body: String)
    case missingServerDate
    case invalidServerDate(String)
    case noAudioReceived
    case unexpectedResponse(String)
    case unknownResponse(String)
    case webSocket(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, _, let body): "Edge TTS 请求失败（HTTP \(status)）：\(body)"
        case .missingServerDate: "Edge TTS 时钟校准失败：响应没有 Date"
        case .invalidServerDate(let date): "Edge TTS 时钟校准失败：无法解析 Date \(date)"
        case .noAudioReceived: "Edge TTS 没有返回音频，请检查音色和文本"
        case .unexpectedResponse(let message): "Edge TTS 响应异常：\(message)"
        case .unknownResponse(let message): "Edge TTS 未知响应：\(message)"
        case .webSocket(let message): "Edge TTS WebSocket 错误：\(message)"
        }
    }
}

/// 文本块同时保存 SSML 文本和原文范围，XML 实体不会改变后续正文的位置。
enum EdgeTTSText {
    struct Chunk: Equatable {
        let escapedText: String
        let range: NSRange
    }

    /// 逐 Unicode 标量填满 4096 字节请求，不截断 UTF-8、XML 实体或删除原文。
    static func chunks(_ text: String) -> [Chunk] {
        var result: [Chunk] = []
        var escapedText = ""
        var bytes = 0
        var start = 0
        var position = 0
        for scalar in removeIncompatible(text).unicodeScalars {
            let value = String(scalar)
            let escaped = escape(value)
            if bytes + escaped.utf8.count > 4096 {
                result.append(.init(escapedText: escapedText, range: NSRange(location: start, length: position - start)))
                escapedText = ""
                bytes = 0
                start = position
            }
            escapedText += escaped
            bytes += escaped.utf8.count
            position += value.utf16.count
        }
        if !escapedText.isEmpty {
            result.append(.init(escapedText: escapedText, range: NSRange(location: start, length: position - start)))
        }
        return result
    }

    /// 按上游协议将 XML 不接受的控制字符替换为空格，原文 UTF-16 位置保持一致。
    static func removeIncompatible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0...8, 11...12, 14...31: Unicode.Scalar(32)!
            default: scalar
            }
        }))
    }

    /// 转义正文中的 XML 保留字符，原文不被当成 SSML 标签执行。
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// 按上游顺序解码一次边界文本，原文中的字面量实体仍保留为原文。
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 将音色短名展开为微软 SSML 声线全名，保留已使用全名的配置。
    static func voiceName(_ voice: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "^([a-z]{2,})-([A-Z]{2,})-(.+Neural)$")
        let range = NSRange(voice.startIndex..., in: voice)
        guard let match = pattern.firstMatch(in: voice, range: range) else { return voice }
        let lang = String(voice[Range(match.range(at: 1), in: voice)!])
        var region = String(voice[Range(match.range(at: 2), in: voice)!])
        var name = String(voice[Range(match.range(at: 3), in: voice)!])
        if let hyphen = name.firstIndex(of: "-") {
            region += "-" + name[..<hyphen]
            name = String(name[name.index(after: hyphen)...])
        }
        return "Microsoft Server Speech Text to Speech Voice (\(lang)-\(region), \(name))"
    }
}

/// 解码微软返回的文字时间点；正文位置由原文的顺序匹配确定。
struct EdgeTTSWordBoundary: Decodable, Equatable {
    let offset: Int64
    let text: String

    private enum CodingKeys: String, CodingKey { case offset = "Offset", text }
    private struct Text: Decodable { let Text: String }

    /// 直接解码协议字段，缺失时间或文字时报告解码失败。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        offset = try values.decode(Int64.self, forKey: .offset)
        text = EdgeTTSText.unescape(try values.decode(Text.self, forKey: .text).Text)
    }
}

/// 按请求块的原文范围建立时间轴，跨块时间使用 MP3 固定码率的实际字节数累计。
struct EdgeTTSTimeline {
    private let text: NSString
    private var cursor = 0
    private(set) var boundaries: [HttpTTSSpeechBoundary] = []

    /// 保存清洗后的原文用于匹配，控制字符替换不改变正文的 UTF-16 索引。
    init(text: String) {
        self.text = EdgeTTSText.removeIncompatible(text) as NSString
    }

    /// 每个词只在所属请求块中从前向后匹配，重复文字不会跳回已播放位置。
    mutating func append(_ words: [EdgeTTSWordBoundary], range: NSRange, precedingAudioBytes: Int) throws {
        let offsetTicks = Int64(precedingAudioBytes) * 8 * 10_000_000 / 48_000
        cursor = max(cursor, range.location)
        for word in words {
            let found = text.range(of: word.text, options: .literal, range: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
            if found.location == NSNotFound {
                throw EdgeTTSError.unexpectedResponse("无法在原文中定位音频文字：\(word.text)")
            }
            boundaries.append(.init(offsetTicks: offsetTicks + word.offset, range: found))
            cursor = NSMaxRange(found)
        }
    }
}

/// 编解码 Edge WebSocket 报文，文字边界随 MP3 一并交给听书队列。
enum EdgeTTSMessage {
    enum TextEvent {
        case turnEnd
        case metadata([EdgeTTSWordBoundary])
        case control
    }

    /// 开启词边界以获得缓存内部的真实朗读位置，音频仍使用固定码率 MP3。
    static func speechConfig(timestamp: String) -> String {
        "X-Timestamp:\(timestamp)\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"true\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
    }

    /// 发送 SSML 时沿用微软客户端时间戳的 Z 后缀。
    static func ssmlRequest(requestID: String, timestamp: String, voice: String, text: String) -> String {
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(EdgeTTSText.voiceName(voice))'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(text)</prosody></voice></speak>"
        return "X-RequestId:\(requestID)\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp)Z\r\nPath:ssml\r\n\r\n" + ssml
    }

    /// 文本帧分别发布结束、控制和文字边界事件，未知路径直接报告协议错误。
    static func textEvent(_ text: String) throws -> TextEvent {
        guard let separator = text.range(of: "\r\n\r\n") else {
            throw EdgeTTSError.unexpectedResponse("文本帧缺少头部分隔")
        }
        let values = try headers(String(text[..<separator.lowerBound]))
        switch values["Path"] {
        case "turn.end": return .turnEnd
        case "response", "turn.start": return .control
        case "audio.metadata":
            let envelope = try JSONDecoder().decode(Metadata.self, from: Data(text[separator.upperBound...].utf8))
            return .metadata(envelope.metadata.compactMap(\.word))
        default: throw EdgeTTSError.unknownResponse("未知文本帧路径：\(text)")
        }
    }

    /// 二进制帧的前两个字节给出头部长度，音频从头部末尾开始读取。
    static func audioPayload(_ message: Data) throws -> Data? {
        guard message.count >= 2 else { throw EdgeTTSError.unexpectedResponse("二进制帧缺少头部长度") }
        let length = Int(message[0]) << 8 | Int(message[1])
        guard length + 2 <= message.count else { throw EdgeTTSError.unexpectedResponse("二进制帧的头部长度超出帧大小") }
        let values = try headers(String(decoding: message[2..<(2 + length)], as: UTF8.self))
        guard values["Path"] == "audio" else { throw EdgeTTSError.unexpectedResponse("二进制帧不是音频") }
        let payload = Data(message[(2 + length)...])
        switch values["Content-Type"] {
        case "audio/mpeg":
            guard !payload.isEmpty else { throw EdgeTTSError.unexpectedResponse("音频帧缺少音频数据") }
            return payload
        case nil where payload.isEmpty: return nil
        default: throw EdgeTTSError.unexpectedResponse("音频帧的 Content-Type 与 MP3 协议不符")
        }
    }

    /// 只拆开首个冒号，时间戳中的冒号保持在头部值内。
    private static func headers(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw EdgeTTSError.unexpectedResponse("报文头缺少冒号") }
            values[String(line[..<colon])] = String(line[line.index(after: colon)...])
        }
        return values
    }

    private struct Metadata: Decodable {
        let metadata: [Item]
        private enum CodingKeys: String, CodingKey { case metadata = "Metadata" }
    }

    /// SessionEnd 不含文字，词或句边界则必须包含完整的 Data 字段。
    private struct Item: Decodable {
        let word: EdgeTTSWordBoundary?
        private enum CodingKeys: String, CodingKey { case type = "Type", data = "Data" }

        /// 根据微软定义的事件类型解码，避免用类型转换隐藏协议变化。
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let type = try values.decode(String.self, forKey: .type)
            switch type {
            case "WordBoundary", "SentenceBoundary": word = try values.decode(EdgeTTSWordBoundary.self, forKey: .data)
            case "SessionEnd": word = nil
            default: throw EdgeTTSError.unknownResponse("未知文字边界类型：\(type)")
            }
        }
    }
}
