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
        var audio = Data()
        var timeline = EdgeTTSTimeline(text: text)
        for chunk in EdgeTTSText.chunks(text) {
            try Task.checkCancellation()
            let value = try await synthesize(chunk.escapedText, voice: configuration.voice, timeout: timeout, allowsClockRetry: true)
            try timeline.append(value.words, range: chunk.range, precedingAudioBytes: audio.count)
            audio.append(value.data)
        }
        return .init(
            data: audio,
            contentType: "audio/mpeg",
            finalURL: URL(string: Self.websocketBaseURL)!,
            speechBoundaries: timeline.boundaries
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

    private func synthesize(_ text: String, voice: String, timeout: TimeInterval, allowsClockRetry: Bool) async throws -> SynthesizedChunk {
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

    /// 一次请求的音频与词边界共同返回，时间轴不会在收集音频时被丢弃。
    private struct SynthesizedChunk {
        let data: Data
        let words: [EdgeTTSWordBoundary]
    }

    /// 每个文本块单独建立 WebSocket，发送配置与 SSML 后收集 MP3 和词边界。
    private func streamAudio(text: String, voice: String, timeout: TimeInterval) async throws -> SynthesizedChunk {
        let connectionID = connectID()
        let token = EdgeTTSGEC.token(unixTimestamp: clock.unixTimestamp())
        let url = URL(string: "\(Self.websocketBaseURL)?TrustedClientToken=\(Self.trustedClientToken)&ConnectionId=\(connectionID)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=\(EdgeTTSGEC.secMSGECVersion)")!
        let socket = try await webSocket.open(url: url, headers: Self.websocketHeaders(muid: muid()), timeout: timeout)
        let stamp = timestamp()
        try await socket.send(text: EdgeTTSMessage.speechConfig(timestamp: stamp))
        try await socket.send(text: EdgeTTSMessage.ssmlRequest(requestID: connectID(), timestamp: stamp, voice: voice, text: text))
        var audio = Data()
        var words: [EdgeTTSWordBoundary] = []
        var receivedAudio = false
        receiveLoop: while true {
            try Task.checkCancellation()
            switch try await socket.receive() {
            case .text(let value):
                switch try EdgeTTSMessage.textEvent(value) {
                case .turnEnd: break receiveLoop
                case .metadata(let boundaries): words.append(contentsOf: boundaries)
                case .control: break
                }
            case .data(let value):
                if let chunk = try EdgeTTSMessage.audioPayload(value) {
                    audio.append(chunk)
                    receivedAudio = true
                }
            case .close:
                throw EdgeTTSError.unexpectedResponse("合成结束前连接已关闭")
            }
        }
        if !receivedAudio { throw EdgeTTSError.noAudioReceived }
        return SynthesizedChunk(data: audio, words: words)
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
