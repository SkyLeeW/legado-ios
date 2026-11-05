import Foundation
import Security

/// Edge 渠道只保存音色短名，合成时再展开为微软 SSML 声线全名。
public struct EdgeTTSConfiguration: Codable, Hashable, Sendable {
    public var voice: String
    public init(voice: String = "zh-CN-XiaoxiaoNeural") { self.voice = voice }
}

/// 官方 voices/list 返回的音色，界面按短名选择。
public struct EdgeTTSVoice: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var shortName: String
    public var gender: String
    public var locale: String
    public var friendlyName: String?
    public var id: String { shortName }
    public var displayName: String {
        let title = friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return "\(title)（\(shortName)）" }
        return shortName
    }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case shortName = "ShortName"
        case gender = "Gender"
        case locale = "Locale"
        case friendlyName = "FriendlyName"
    }
}

/// Edge 合成失败直接展示，不改走其他协议或静默重试。
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
        case .http(let status, _, let body):
            "Edge TTS 请求失败（HTTP \(status)）：\(body)"
        case .missingServerDate:
            "Edge TTS 时钟校准失败：响应没有 Date"
        case .invalidServerDate(let date):
            "Edge TTS 时钟校准失败：无法解析 Date \(date)"
        case .noAudioReceived:
            "Edge TTS 没有返回音频，请检查音色和文本"
        case .unexpectedResponse(let message):
            "Edge TTS 响应异常：\(message)"
        case .unknownResponse(let message):
            "Edge TTS 未知响应：\(message)"
        case .webSocket(let message):
            "Edge TTS WebSocket 错误：\(message)"
        }
    }
}

public extension HttpTTS {
    /// 创建可直接出现在听书引擎列表中的 Edge 渠道，输出 MP3 音频。
    static func edgeEngine() -> HttpTTS {
        var engine = HttpTTS(name: "Microsoft Edge", url: EdgeTTSService.websocketBaseURL)
        engine.edge = EdgeTTSConfiguration()
        engine.contentType = "audio/mpeg"
        return engine
    }
}

/// 测试可注入的 WebSocket 会话，正式环境由 URLSession 实现。
protocol EdgeTTSWebSocket: Sendable {
    func send(text: String) async throws
    func receive() async throws -> EdgeTTSWebSocketMessage
}

enum EdgeTTSWebSocketMessage: Sendable {
    case text(String)
    case data(Data)
    case close
}

protocol EdgeTTSWebSocketConnecting: Sendable {
    func open(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> any EdgeTTSWebSocket
}

/// 按 edge-tts Communicate 协议把正文切块、构造 SSML 并从 WebSocket 收集 MP3。
struct EdgeTTSService: Sendable {
    static let websocketBaseURL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    static let voiceListURL = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list"
    static let trustedClientToken = EdgeTTSGEC.trustedClientToken
    private static let chunkLimit = 4096

    let transport: any HTTPTransport
    let webSocket: any EdgeTTSWebSocketConnecting
    let clock: EdgeTTSClock
    let connectID: @Sendable () -> String
    let muid: @Sendable () -> String
    let timestamp: @Sendable () -> String

    init(
        transport: any HTTPTransport,
        webSocket: any EdgeTTSWebSocketConnecting,
        clock: EdgeTTSClock,
        connectID: @escaping @Sendable () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() },
        muid: @escaping @Sendable () -> String = { EdgeTTSService.randomMUID() },
        timestamp: @escaping @Sendable () -> String = { EdgeTTSService.javascriptDate() }
    ) {
        self.transport = transport
        self.webSocket = webSocket
        self.clock = clock
        self.connectID = connectID
        self.muid = muid
        self.timestamp = timestamp
    }

    /// 合成完整 MP3；403 只按官方流程校准时钟后再请求一次。
    func audio(configuration: EdgeTTSConfiguration, text: String, timeout: TimeInterval = 300) async throws -> HttpTTSAudio {
        let chunks = try EdgeTTSText.prepare(text)
        var audio = Data()
        for chunk in chunks {
            try Task.checkCancellation()
            audio.append(try await synthesize(chunk, voice: configuration.voice, timeout: timeout, allowsClockRetry: true))
        }
        return .init(
            data: audio,
            contentType: "audio/mpeg",
            finalURL: URL(string: Self.websocketBaseURL)!
        )
    }

    /// 拉取官方音色列表，403 时校准时钟后重拉一次。
    func voices(timeout: TimeInterval = 300) async throws -> [EdgeTTSVoice] {
        do {
            return try await fetchVoices(timeout: timeout)
        } catch let error as EdgeTTSError {
            if case .http(let status, let headers, _) = error, status == 403 {
                try clock.handleForbidden(headers: headers)
                return try await fetchVoices(timeout: timeout)
            }
            throw error
        }
    }

    /// 生成 32 位大写十六进制 MUID，写入 Cookie。
    static func randomMUID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// 生成 edge-tts 使用的 Javascript 风格 UTC 时间戳。
    static func javascriptDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss"
        return formatter.string(from: date) + " GMT+0000 (Coordinated Universal Time)"
    }

    private func fetchVoices(timeout: TimeInterval) async throws -> [EdgeTTSVoice] {
        let token = EdgeTTSGEC.token(unixTimestamp: clock.unixTimestamp())
        var request = URLRequest(
            url: URL(string: "\(Self.voiceListURL)?trustedclienttoken=\(Self.trustedClientToken)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=\(EdgeTTSGEC.secMSGECVersion)")!
        )
        request.timeoutInterval = timeout
        for (key, value) in Self.voiceHeaders(muid: muid()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let response: HTTPResponse
        do {
            response = try await transport.data(for: request)
        } catch HTTPClientError.statusResponse(let failure) {
            throw EdgeTTSError.http(status: failure.statusCode, headers: failure.headers, body: failure.decodedText)
        }
        guard (200...299).contains(response.statusCode) else {
            throw EdgeTTSError.http(status: response.statusCode, headers: response.headers, body: response.decodedText)
        }
        return try JSONDecoder().decode([EdgeTTSVoice].self, from: response.data)
    }

    private func synthesize(_ text: String, voice: String, timeout: TimeInterval, allowsClockRetry: Bool) async throws -> Data {
        do {
            return try await streamAudio(text: text, voice: voice, timeout: timeout)
        } catch let error as EdgeTTSError {
            if case .http(let status, let headers, _) = error, status == 403, allowsClockRetry {
                try clock.handleForbidden(headers: headers)
                return try await streamAudio(text: text, voice: voice, timeout: timeout)
            }
            throw error
        }
    }

    /// 每个文本块单独建立 WebSocket，发送 speech.config 与 SSML 后收集音频。
    private func streamAudio(text: String, voice: String, timeout: TimeInterval) async throws -> Data {
        let connectionID = connectID()
        let token = EdgeTTSGEC.token(unixTimestamp: clock.unixTimestamp())
        let url = URL(string: "\(Self.websocketBaseURL)?TrustedClientToken=\(Self.trustedClientToken)&ConnectionId=\(connectionID)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=\(EdgeTTSGEC.secMSGECVersion)")!
        let socket = try await webSocket.open(url: url, headers: Self.websocketHeaders(muid: muid()), timeout: timeout)
        let stamp = timestamp()
        try await socket.send(text: EdgeTTSMessage.speechConfig(timestamp: stamp))
        try await socket.send(text: EdgeTTSMessage.ssmlRequest(requestID: connectID(), timestamp: stamp, voice: voice, text: text))
        var audio = Data()
        var receivedAudio = false
        receiveLoop: while true {
            try Task.checkCancellation()
            switch try await socket.receive() {
            case .text(let value):
                if try EdgeTTSMessage.isTurnEnd(value) { break receiveLoop }
            case .data(let value):
                if let chunk = try EdgeTTSMessage.audioPayload(value) {
                    audio.append(chunk)
                    receivedAudio = true
                }
            case .close:
                break receiveLoop
            }
        }
        if !receivedAudio { throw EdgeTTSError.noAudioReceived }
        return audio
    }

    private static func websocketHeaders(muid: String) -> [String: String] {
        [
            "Pragma": "no-cache",
            "Cache-Control": "no-cache",
            "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            "Sec-WebSocket-Version": "13",
            "User-Agent": userAgent,
            "Accept-Encoding": "gzip, deflate, br, zstd",
            "Accept-Language": "en-US,en;q=0.9",
            "Cookie": "muid=\(muid);"
        ]
    }

    private static func voiceHeaders(muid: String) -> [String: String] {
        [
            "Authority": "speech.platform.bing.com",
            "Sec-CH-UA": "\" Not;A Brand\";v=\"99\", \"Microsoft Edge\";v=\"\(EdgeTTSGEC.chromiumMajor)\", \"Chromium\";v=\"\(EdgeTTSGEC.chromiumMajor)\"",
            "Sec-CH-UA-Mobile": "?0",
            "Accept": "*/*",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "User-Agent": userAgent,
            "Accept-Encoding": "gzip, deflate, br, zstd",
            "Accept-Language": "en-US,en;q=0.9",
            "Cookie": "muid=\(muid);"
        ]
    }

    private static var userAgent: String {
        let major = EdgeTTSGEC.chromiumMajor
        return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0"
    }
}

/// 文本清洗、XML 转义和按 4096 字节切块，切分规则与 edge-tts 一致。
enum EdgeTTSText {
    /// 去掉控制字符、转义 XML 后按服务端字节上限切块。
    static func prepare(_ text: String) throws -> [String] {
        try split(escape(removeIncompatible(text)), byteLength: 4096)
    }

    /// 把微软不接受的控制字符替换为空格，保留换行。
    static func removeIncompatible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            let code = scalar.value
            if (0...8).contains(code) || (11...12).contains(code) || (14...31).contains(code) {
                return Unicode.Scalar(32)!
            }
            return scalar
        }))
    }

    /// 按 xml.sax.saxutils.escape 的顺序转义 &、<、>。
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// 把短名展开为微软 SSML 使用的完整声线名。
    static func voiceName(_ voice: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "^([a-z]{2,})-([A-Z]{2,})-(.+Neural)$")
        let range = NSRange(voice.startIndex..., in: voice)
        guard let match = pattern.firstMatch(in: voice, range: range) else { return voice }
        let lang = Range(match.range(at: 1), in: voice).map { String(voice[$0]) }!
        var region = Range(match.range(at: 2), in: voice).map { String(voice[$0]) }!
        var name = Range(match.range(at: 3), in: voice).map { String(voice[$0]) }!
        if let hyphen = name.firstIndex(of: "-") {
            region = "\(region)-\(name[..<hyphen])"
            name = String(name[name.index(after: hyphen)...])
        }
        return "Microsoft Server Speech Text to Speech Voice (\(lang)-\(region), \(name))"
    }

    /// 优先在换行或空格处切开，并保证 UTF-8 与未结束的 XML 实体不被截断。
    static func split(_ text: String, byteLength: Int) throws -> [String] {
        var data = Data(text.utf8)
        var chunks: [String] = []
        while data.count > byteLength {
            var splitAt = lastBreak(in: data, limit: byteLength)
            if splitAt < 0 { splitAt = utf8Boundary(data) }
            splitAt = xmlEntityBoundary(data, splitAt: splitAt)
            if splitAt < 0 {
                throw EdgeTTSError.unexpectedResponse("Maximum byte length is too small or invalid text structure near '&' or invalid UTF-8")
            }
            let chunk = strip(data.prefix(splitAt))
            if !chunk.isEmpty { chunks.append(String(decoding: chunk, as: UTF8.self)) }
            data = Data(data[(splitAt > 0 ? splitAt : 1)...])
        }
        let remaining = strip(data)
        if !remaining.isEmpty { chunks.append(String(decoding: remaining, as: UTF8.self)) }
        return chunks
    }

    private static func lastBreak(in data: Data, limit: Int) -> Int {
        let prefix = data.prefix(limit)
        if let newline = prefix.lastIndex(of: 0x0A) { return prefix.distance(from: prefix.startIndex, to: newline) }
        if let space = prefix.lastIndex(of: 0x20) { return prefix.distance(from: prefix.startIndex, to: space) }
        return -1
    }

    private static func utf8Boundary(_ data: Data) -> Int {
        var splitAt = data.count
        while splitAt > 0 {
            if String(data: data.prefix(splitAt), encoding: .utf8) != nil { return splitAt }
            splitAt -= 1
        }
        return splitAt
    }

    private static func xmlEntityBoundary(_ data: Data, splitAt: Int) -> Int {
        var splitAt = splitAt
        while splitAt > 0, data.prefix(splitAt).contains(0x26) {
            let prefix = data.prefix(splitAt)
            let ampersand = prefix.lastIndex(of: 0x26)!
            let ampersandIndex = prefix.distance(from: prefix.startIndex, to: ampersand)
            if prefix[prefix.index(prefix.startIndex, offsetBy: ampersandIndex)..<prefix.endIndex].contains(0x3B) {
                break
            }
            splitAt = ampersandIndex
        }
        return splitAt
    }

    private static func strip(_ data: Data) -> Data {
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]
        var start = 0
        var end = data.count
        while start < end, whitespace.contains(data[start]) { start += 1 }
        while end > start, whitespace.contains(data[end - 1]) { end -= 1 }
        return Data(data[start..<end])
    }

}

/// 构造并解析 edge-tts 的文本/二进制 WebSocket 报文。
enum EdgeTTSMessage {
    /// 发送合成配置，固定使用 24kHz 48kbps 单声道 MP3。
    static func speechConfig(timestamp: String) -> String {
        "X-Timestamp:\(timestamp)\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"true\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
    }

    /// 发送 SSML，X-Timestamp 按微软客户端的多余 Z 后缀拼接。
    static func ssmlRequest(requestID: String, timestamp: String, voice: String, text: String) -> String {
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(EdgeTTSText.voiceName(voice))'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(text)</prosody></voice></speak>"
        return "X-RequestId:\(requestID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(timestamp)Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml
    }

    /// 解析文本帧路径，turn.end 结束当前块，未知路径按协议报错。
    static func isTurnEnd(_ text: String) throws -> Bool {
        let data = Data(text.utf8)
        guard let headerLength = index(of: [0x0D, 0x0A, 0x0D, 0x0A], in: data) else {
            throw EdgeTTSError.unexpectedResponse("文本帧缺少头部分隔")
        }
        let headers = try headersAndBody(data, headerLength: headerLength).0
        guard let path = headers[Data("Path".utf8)] else {
            throw EdgeTTSError.unknownResponse("Unknown path received")
        }
        switch path {
        case Data("turn.end".utf8):
            return true
        case Data("audio.metadata".utf8):
            try parseMetadata(headersAndBody(data, headerLength: headerLength).1)
            return false
        case Data("response".utf8), Data("turn.start".utf8):
            return false
        default:
            throw EdgeTTSError.unknownResponse("Unknown path received")
        }
    }

    /// 从二进制帧取出 MP3 负载，空的结束帧返回 nil。
    static func audioPayload(_ message: Data) throws -> Data? {
        if message.count < 2 {
            throw EdgeTTSError.unexpectedResponse("We received a binary message, but it is missing the header length.")
        }
        let headerLength = Int(message[0]) << 8 | Int(message[1])
        if headerLength > message.count {
            throw EdgeTTSError.unexpectedResponse("The header length is greater than the length of the data.")
        }
        let parsed = try headersAndBody(message, headerLength: headerLength)
        if parsed.0[Data("Path".utf8)] != Data("audio".utf8) {
            throw EdgeTTSError.unexpectedResponse("Received binary message, but the path is not audio.")
        }
        let contentType = parsed.0[Data("Content-Type".utf8)]
        if contentType != Data("audio/mpeg".utf8) && contentType != nil {
            throw EdgeTTSError.unexpectedResponse("Received binary message, but with an unexpected Content-Type.")
        }
        if contentType == nil {
            if parsed.1.isEmpty { return nil }
            throw EdgeTTSError.unexpectedResponse("Received binary message with no Content-Type, but with data.")
        }
        if parsed.1.isEmpty {
            throw EdgeTTSError.unexpectedResponse("Received binary message, but it is missing the audio data.")
        }
        return parsed.1
    }

    /// 按 edge-tts get_headers_and_data 切分头部与正文。
    static func headersAndBody(_ data: Data, headerLength: Int) throws -> ([Data: Data], Data) {
        let headerData = Data(data.prefix(headerLength))
        var headers: [Data: Data] = [:]
        for line in splitCRLF(headerData) {
            guard let colon = line.firstIndex(of: 0x3A) else {
                throw EdgeTTSError.unexpectedResponse("报文头缺少分隔符")
            }
            headers[Data(line[..<colon])] = Data(line[line.index(after: colon)...])
        }
        let bodyStart = min(headerLength + 2, data.count)
        return (headers, Data(data[bodyStart...]))
    }

    /// 按 CRLF 拆行，空段保留，与 Python bytes.split 相同。
    private static func splitCRLF(_ data: Data) -> [Data] {
        var parts: [Data] = []
        var start = 0
        var index = 0
        while index + 1 < data.count {
            if data[index] == 0x0D && data[index + 1] == 0x0A {
                parts.append(Data(data[start..<index]))
                start = index + 2
                index = start
                continue
            }
            index += 1
        }
        parts.append(Data(data[start...]))
        return parts
    }

    /// 在字节序列中查找固定模式的起始下标，供 iOS 15 解析 WebSocket 文本帧。
    private static func index(of pattern: [UInt8], in data: Data) -> Int? {
        guard data.count >= pattern.count else { return nil }
        let last = data.count - pattern.count
        var offset = 0
        while offset <= last {
            var matched = true
            var index = 0
            while index < pattern.count {
                if data[offset + index] != pattern[index] {
                    matched = false
                    break
                }
                index += 1
            }
            if matched { return offset }
            offset += 1
        }
        return nil
    }

    /// 校验 metadata 类型，只接受句/词边界，SessionEnd 可忽略。
    private static func parseMetadata(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any], let items = root["Metadata"] as? [[String: Any]] else {
            throw EdgeTTSError.unexpectedResponse("No WordBoundary metadata found")
        }
        for item in items {
            guard let type = item["Type"] as? String else {
                throw EdgeTTSError.unexpectedResponse("No WordBoundary metadata found")
            }
            if type == "WordBoundary" || type == "SentenceBoundary" { return }
            if type == "SessionEnd" { continue }
            throw EdgeTTSError.unknownResponse("Unknown metadata type: \(type)")
        }
        throw EdgeTTSError.unexpectedResponse("No WordBoundary metadata found")
    }
}

/// 用 URLSessionWebSocketTask 建立 Edge 合成连接，握手失败时保留 HTTP 状态和 Date。
final class URLSessionEdgeTTSWebSocketConnecting: EdgeTTSWebSocketConnecting, Sendable {
    func open(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> any EdgeTTSWebSocket {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let sessionDelegate = Delegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        sessionDelegate.task = task
        task.resume()
        try await sessionDelegate.waitUntilOpen()
        return Socket(session: session, task: task, delegate: sessionDelegate)
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        var task: URLSessionWebSocketTask?
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var opened = false
        private var finished = false
        private var handshake: HTTPURLResponse?

        func waitUntilOpen() async throws {
            try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, Error>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    value.resume()
                    return
                }
                if finished {
                    let error = mappedError()
                    lock.unlock()
                    value.resume(throwing: error)
                    return
                }
                continuation = value
                lock.unlock()
            }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            finish(opened: true, error: nil, response: webSocketTask.response as? HTTPURLResponse)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(opened: false, error: error, response: task.response as? HTTPURLResponse)
        }

        private func finish(opened success: Bool, error: Error?, response: HTTPURLResponse?) {
            lock.lock()
            if response != nil { handshake = response }
            if opened { lock.unlock(); return }
            if success {
                opened = true
                finished = true
                let continuation = continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume()
                return
            }
            if finished { lock.unlock(); return }
            finished = true
            handshake = handshake ?? response
            let mapped = mappedError(error)
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: mapped)
        }

        private func mappedError(_ error: Error? = nil) -> Error {
            if let handshake, !(200...299).contains(handshake.statusCode) {
                var headers: [String: String] = [:]
                for (key, value) in handshake.allHeaderFields {
                    headers["\(key)"] = "\(value)"
                }
                return EdgeTTSError.http(status: handshake.statusCode, headers: headers, body: "")
            }
            return EdgeTTSError.webSocket(error?.localizedDescription ?? "连接失败")
        }
    }

    private final class Socket: EdgeTTSWebSocket, @unchecked Sendable {
        private let session: URLSession
        private let task: URLSessionWebSocketTask
        private let delegate: Delegate

        init(session: URLSession, task: URLSessionWebSocketTask, delegate: Delegate) {
            self.session = session
            self.task = task
            self.delegate = delegate
        }

        deinit {
            task.cancel(with: .goingAway, reason: nil)
            session.finishTasksAndInvalidate()
        }

        func send(text: String) async throws {
            try await task.send(.string(text))
        }

        func receive() async throws -> EdgeTTSWebSocketMessage {
            do {
                switch try await task.receive() {
                case .string(let text):
                    return .text(text)
                case .data(let data):
                    return .data(data)
                @unknown default:
                    throw EdgeTTSError.unknownResponse("Unknown websocket message")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if task.closeCode == .normalClosure || task.closeCode == .goingAway {
                    return .close
                }
                throw EdgeTTSError.webSocket(error.localizedDescription)
            }
        }
    }
}
