import Foundation
import Testing
@testable import LegadoCore

/// 对照 edge-tts 协议检查令牌、切块、WebSocket 报文和缓存，不访问真实微软接口。
struct EdgeTTSTests {
    /// Sec-MS-GEC v2 必须与 edge-tts 在相同 Unix 时间下给出的令牌一致。
    @Test(arguments: [
        (0.0, "52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6"),
        (1_700_000_000.0, "2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2"),
        (1_762_300_000.0, "A333B4920DBC24D4-89730AD48DFA0B7DFB93BD08837E7D8F2A465B82F9866A891FB7AE7B3D7107BD"),
        (1_762_345_678.9, "DDEA8CA76EA180DE-BFD7562FA886ECD49E8EBA121718976D4872835CF3991B602B95660B4022EE5A"),
        (2_000_000_000.0, "2D62557F1142BC5D-FD9C30C68FF194A5EE6B45FEFC5E2BA1D1239F88A90569AB55CFFFAA7799F40E")
    ])
    func generatesOfficialGECToken(unix: TimeInterval, token: String) {
        #expect(EdgeTTSGEC.token(unixTimestamp: unix) == token)
    }

    /// 短名展开规则与 edge-tts TTSConfig 一致，已是全名的声线保持原样。
    @Test func expandsVoiceShortNames() {
        #expect(EdgeTTSText.voiceName("zh-CN-XiaoxiaoNeural") == "Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)")
        #expect(EdgeTTSText.voiceName("en-US-EmmaMultilingualNeural") == "Microsoft Server Speech Text to Speech Voice (en-US, EmmaMultilingualNeural)")
        #expect(EdgeTTSText.voiceName("fil-PH-AngeloNeural") == "Microsoft Server Speech Text to Speech Voice (fil-PH, AngeloNeural)")
        #expect(EdgeTTSText.voiceName("Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)")
            == "Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)")
    }

    /// 控制字符替换和 XML 转义沿用协议规则，短文本保持原文范围。
    @Test func preparesTextLikeEdgeTTS() throws {
        #expect(EdgeTTSText.removeIncompatible("\u{00}A\u{0b}B\u{1f}C\nD") == " A B C\nD")
        #expect(EdgeTTSText.escape("路径 C:\\书籍 & 阅读 <tag>") == "路径 C:\\书籍 &amp; 阅读 &lt;tag&gt;")
        #expect(EdgeTTSText.chunks("短句") == [.init(escapedText: "短句", range: NSRange(location: 0, length: 2))])
    }

    /// 合成请求发送 speech.config 与 SSML，并把二进制 MP3 帧拼接为完整音频。
    @Test func sendsConfigAndCollectsMP3() async throws {
        let audio = Data("MP3DATA".utf8)
        let socket = QueueSocket(messages: [
            .text("Path:turn.start\r\n\r\n"),
            .text("Path:audio.metadata\r\n\r\n{\"Metadata\":[{\"Type\":\"WordBoundary\",\"Data\":{\"Offset\":1000000,\"text\":{\"Text\":\"你好\"}}}]}"),
            .data(audioFrame(audio)),
            .text("Path:turn.end\r\n\r\n")
        ])
        let connecting = QueueConnecting(results: [.success(socket)])
        let clock = EdgeTTSClock(now: { 1_762_300_000 })
        let service = EdgeTTSService(
            transport: EdgeRecordingTransport(result: .success(HTTPResponse(data: Data(), statusCode: 200, headers: [:], finalURL: URL(string: "https://example.test")!))),
            webSocket: connecting,
            clock: clock,
            connectID: { "connid" },
            muid: { "MUID" },
            timestamp: { "Wed Nov 05 2026 00:00:00 GMT+0000 (Coordinated Universal Time)" }
        )
        let value = try await service.audio(configuration: .init(voice: "zh-CN-XiaoxiaoNeural"), text: "你好")
        #expect(value.data == audio)
        #expect(value.contentType == "audio/mpeg")
        #expect(value.speechBoundaries == [.init(offsetTicks: 1_000_000, range: NSRange(location: 0, length: 2))])
        let sent = socket.sentTexts()
        #expect(sent.count == 2)
        #expect(sent[0].contains("Path:speech.config"))
        #expect(sent[0].contains("audio-24khz-48kbitrate-mono-mp3"))
        #expect(sent[0].contains("\"wordBoundaryEnabled\":\"true\""))
        #expect(sent[1].contains("Path:ssml"))
        #expect(sent[1].contains("Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)"))
        #expect(sent[1].contains("你好"))
        let url = connecting.urls()[0].absoluteString
        #expect(url.contains("TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4"))
        #expect(url.contains("Sec-MS-GEC=A333B4920DBC24D4-89730AD48DFA0B7DFB93BD08837E7D8F2A465B82F9866A891FB7AE7B3D7107BD"))
        #expect(url.contains("Sec-MS-GEC-Version=2-143.0.3650.75"))
    }

    /// 403 只根据 Date 校准时钟后重试一次，第二次成功不得再发第三次。
    @Test func retriesOnceAfterClockSkew() async throws {
        let audio = Data("RETRY".utf8)
        let forbidden = EdgeTTSError.http(
            status: 403,
            headers: ["Date": "Wed, 21 Oct 2015 07:28:00 GMT"],
            body: ""
        )
        let socket = QueueSocket(messages: [
            .data(audioFrame(audio)),
            .text("Path:turn.end\r\n\r\n")
        ])
        let connecting = QueueConnecting(results: [.failure(forbidden), .success(socket)])
        let clock = EdgeTTSClock(now: { 1_762_300_000 })
        let service = EdgeTTSService(
            transport: EdgeRecordingTransport(result: .success(HTTPResponse(data: Data(), statusCode: 200, headers: [:], finalURL: URL(string: "https://example.test")!))),
            webSocket: connecting,
            clock: clock,
            connectID: { "connid" },
            muid: { "MUID" },
            timestamp: { "stamp" }
        )
        let value = try await service.audio(configuration: .init(), text: "校准")
        #expect(value.data == audio)
        #expect(connecting.urls().count == 2)
        #expect(clock.unixTimestamp() == 1_445_412_480)
    }

    /// 没有 Date 的 403 不能猜测时钟，必须报告校准失败。
    @Test func forbiddenWithoutDateDoesNotRetry() async throws {
        let connecting = QueueConnecting(results: [.failure(EdgeTTSError.http(status: 403, headers: [:], body: ""))])
        let service = EdgeTTSService(
            transport: EdgeRecordingTransport(result: .success(HTTPResponse(data: Data(), statusCode: 200, headers: [:], finalURL: URL(string: "https://example.test")!))),
            webSocket: connecting,
            clock: EdgeTTSClock(now: { 1_762_300_000 })
        )
        await #expect(throws: EdgeTTSError.missingServerDate) {
            try await service.audio(configuration: .init(), text: "失败")
        }
        #expect(connecting.urls().count == 1)
    }

    /// 没有音频就结束连接时按协议报错，不能当成空白成功。
    @Test func missingAudioIsError() async throws {
        let socket = QueueSocket(messages: [.text("Path:turn.end\r\n\r\n")])
        let connecting = QueueConnecting(results: [.success(socket)])
        let service = EdgeTTSService(
            transport: EdgeRecordingTransport(result: .success(HTTPResponse(data: Data(), statusCode: 200, headers: [:], finalURL: URL(string: "https://example.test")!))),
            webSocket: connecting,
            clock: EdgeTTSClock(now: { 1_762_300_000 })
        )
        await #expect(throws: EdgeTTSError.noAudioReceived) {
            try await service.audio(configuration: .init(), text: "空")
        }
    }

    /// 段首空白必须保留在请求与时间轴中，否则定位正文时会提前翻页。
    @Test func preservesLeadingWhitespaceInSpeechPositions() async throws {
        let socket = QueueSocket(messages: [
            .text("Path:audio.metadata\r\n\r\n{\"Metadata\":[{\"Type\":\"WordBoundary\",\"Data\":{\"Offset\":1000000,\"text\":{\"Text\":\"你好\"}}}]}"),
            .data(audioFrame(Data("audio".utf8))), .text("Path:turn.end\r\n\r\n")
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        let service = HttpTTSService(cache: .init(directory: directory), edgeWebSocket: QueueConnecting(results: [.success(socket)]))
        let audio = try await service.audio(engine: .edgeEngine(), text: "  你好\n", speechRate: 5)
        #expect(audio.speechBoundaries.first?.range.location == 2)
        #expect(socket.sentTexts()[1].contains(">  你好\n</prosody>"))
    }

    /// 音色列表请求带令牌，解码官方 JSON 字段。
    @Test func listsOfficialVoices() async throws {
        let body = Data("""
        [{"Name":"Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)","ShortName":"zh-CN-XiaoxiaoNeural","Gender":"Female","Locale":"zh-CN","FriendlyName":"Xiaoxiao"}]
        """.utf8)
        let transport = EdgeRecordingTransport(result: .success(HTTPResponse(
            data: body,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            finalURL: URL(string: EdgeTTSService.voiceListURL)!
        )))
        let service = EdgeTTSService(
            transport: transport,
            webSocket: QueueConnecting(results: []),
            clock: EdgeTTSClock(now: { 1_762_300_000 }),
            muid: { "MUID" }
        )
        let voices = try await service.voices()
        #expect(voices.map(\.shortName) == ["zh-CN-XiaoxiaoNeural"])
        #expect(voices[0].displayName.contains("Xiaoxiao"))
        let request = await transport.requests()[0]
        #expect(request.url?.absoluteString.contains("trustedclienttoken=") == true)
        #expect(request.url?.absoluteString.contains("Sec-MS-GEC=") == true)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "muid=MUID;")
    }

    /// 通用听书入口走 Edge 协议，缓存按音色和正文区分，不受保存时间影响。
    @Test func reusesDecodedCacheAndSeparatesVoices() async throws {
        let audio = Data("edge-audio".utf8)
        let socket = QueueSocket(messages: [
            .text("Path:audio.metadata\r\n\r\n{\"Metadata\":[{\"Type\":\"WordBoundary\",\"Data\":{\"Offset\":1000000,\"text\":{\"Text\":\"第一段\"}}}]}"),
            .data(audioFrame(audio)), .text("Path:turn.end\r\n\r\n")
        ])
        let connecting = QueueConnecting(results: [.success(socket), .success(QueueSocket(messages: [.data(audioFrame(Data("other".utf8))), .text("Path:turn.end\r\n\r\n")]))])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HttpTTSService(
            cache: .init(directory: directory),
            edgeWebSocket: connecting,
            edgeClock: EdgeTTSClock(now: { 1_762_300_000 })
        )
        var engine = HttpTTS.edgeEngine()
        let first = try await service.audio(engine: engine, text: "第一段", speechRate: 5)
        #expect(first.data == audio)
        engine.lastUpdateTime += 1
        let cached = try await service.audio(engine: engine, text: "第一段", speechRate: 10)
        #expect(cached.data == audio)
        #expect(cached.speechBoundaries == first.speechBoundaries)
        #expect(cached.speechBoundaries.count == 1)
        #expect(connecting.urls().count == 1)
        engine.edge = .init(voice: "zh-CN-YunxiNeural")
        _ = try await service.audio(engine: engine, text: "第一段", speechRate: 10)
        #expect(connecting.urls().count == 2)
    }

    /// 导出配置保留 Edge 音色，不把临时令牌写入 JSON。
    @Test func roundTripsChannelWithoutToken() throws {
        var engine = HttpTTS.edgeEngine()
        engine.edge = .init(voice: "zh-CN-YunxiNeural")
        let data = try JSONEncoder().encode(engine)
        let decoded = try JSONDecoder().decode(HttpTTS.self, from: data)
        #expect(decoded == engine)
        #expect(decoded.edge?.voice == "zh-CN-YunxiNeural")
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("Sec-MS-GEC"))
        #expect(!json.contains("6A5AA1D4EAFF4E9FB37E23D68491D6F4"))
    }

    /// RFC 1123 Date 用于时钟校准。
    @Test func parsesHTTPDate() {
        #expect(EdgeTTSGEC.parseHTTPDate("Wed, 21 Oct 2015 07:28:00 GMT") == 1_445_412_480)
    }
}

/// 按真实服务端定义构造二进制帧，头部长度包含末尾 CRLF，但不包含长度字段自身。
private func audioFrame(_ payload: Data) -> Data {
    let header = Data("X-RequestId:abc\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n".utf8)
    var message = Data()
    var headerLength = UInt16(header.count).bigEndian
    message.append(Data(bytes: &headerLength, count: 2))
    message.append(header)
    message.append(payload)
    return message
}

/// 按预定结果开关连接，并记录实际请求的 WebSocket URL。
private final class QueueConnecting: EdgeTTSWebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<QueueSocket, Error>]
    private var opened: [URL] = []

    init(results: [Result<QueueSocket, Error>]) { self.results = results }

    func open(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> any EdgeTTSWebSocket {
        lock.lock()
        opened.append(url)
        let result = results.removeFirst()
        lock.unlock()
        return try result.get()
    }

    func urls() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }
}

/// 按顺序吐出预定帧，并记录发送给服务端的文本报文。
private final class QueueSocket: EdgeTTSWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [EdgeTTSWebSocketMessage]
    private var sent: [String] = []

    init(messages: [EdgeTTSWebSocketMessage]) { self.messages = messages }

    func send(text: String) async throws {
        lock.lock(); sent.append(text); lock.unlock()
    }

    func receive() async throws -> EdgeTTSWebSocketMessage {
        lock.lock()
        if messages.isEmpty { lock.unlock(); return .close }
        let value = messages.removeFirst()
        lock.unlock()
        return value
    }

    func sentTexts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }
}

/// 记录 HTTP 请求并返回固定结果，供音色列表用例检查令牌参数。
private actor EdgeRecordingTransport: HTTPTransport {
    let result: Result<HTTPResponse, any Error>
    private var values: [URLRequest] = []

    init(result: Result<HTTPResponse, any Error>) { self.result = result }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        values.append(request)
        return try result.get()
    }

    func requests() -> [URLRequest] { values }
}
