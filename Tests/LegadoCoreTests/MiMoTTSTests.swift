import Foundation
import Testing
@testable import LegadoCore

/// 使用自造响应检查渠道协议和缓存，不访问真实接口或个人密钥。
struct MiMoTTSTests {
    /// 请求必须使用固定模型与地址，并将含特殊字符的原文放入 assistant 消息。
    @Test func sendsOfficialRequestAndDecodesAudio() async throws {
        let bytes = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF])
        let transport = MiMoRecordingTransport(result: .success(try response(audio: bytes)))
        let service = MiMoTTSService(transport: transport, apiKey: { _ in "test-key" })
        let text = "他说：\"你好\"。\n路径 C:\\书籍，emoji 📖"
        let audio = try await service.audio(engineID: 7, configuration: .init(voice: .suDa), text: text)
        let requests = await transport.requests
        let request = try #require(requests.first)
        let bodyData = try #require(request.httpBody)
        let body = try JSONValue.decode(data: bodyData)

        #expect(request.url == MiMoTTSConfiguration.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(body == .object([
            "model": .string("mimo-v2.5-tts"),
            "stream": .bool(false),
            "messages": .array([.object(["role": .string("assistant"), "content": .string(text)])]),
            "audio": .object(["format": .string("wav"), "voice": .string("苏打")])
        ]))
        #expect(audio.data == bytes)
        #expect(audio.contentType == "audio/wav")
        #expect(requests.count == 1)
    }

    /// 通用流式入口应输出解码后的 WAV，缓存不受保存时间和无效语速参数影响。
    @Test func reusesDecodedCacheAndSeparatesVoices() async throws {
        let bytes = Data("audio-fixture".utf8)
        let transport = MiMoRecordingTransport(result: .success(try response(audio: bytes)))
        let directory = try makeCacheDirectory()
        defer { removeCacheDirectory(directory) }
        let service = HttpTTSService(transport: transport, cache: .init(directory: directory), miMoAPIKey: { _ in "test-key" })
        var engine = HttpTTS.miMoEngine()
        let stream = try await service.audioStream(engine: engine, text: "第一段", speechRate: 5)
        var received = Data()
        for try await chunk in stream.chunks { received.append(chunk) }
        #expect(!stream.isIncremental)
        #expect(stream.contentType == "audio/wav")
        #expect(received == bytes)

        engine.lastUpdateTime += 1
        let cached = try await service.audio(engine: engine, text: "第一段", speechRate: 10)
        #expect(cached.data == bytes)
        #expect(await transport.requests.count == 1)

        // 试听重新请求，避免用户更换密钥后被旧音频缓存误导。
        _ = try await service.audio(engine: engine, text: "第一段", speechRate: 10, cachePolicy: .reload)
        #expect(await transport.requests.count == 2)

        engine.mimo = .init(voice: .baiHua)
        _ = try await service.audio(engine: engine, text: "第一段", speechRate: 10)
        #expect(await transport.requests.count == 3)
    }

    /// 未配置密钥时直接报告配置缺失，不向服务端发送请求。
    @Test func missingKeyDoesNotSendRequest() async throws {
        let transport = MiMoRecordingTransport(result: .success(try response(audio: Data())))
        let service = MiMoTTSService(transport: transport, apiKey: { _ in nil })
        await #expect(throws: MiMoTTSError.missingAPIKey) {
            try await service.audio(engineID: 7, configuration: .init(), text: "测试")
        }
        #expect(await transport.requests.isEmpty)
    }

    /// 密钥读取失败必须原样抛出，不能被当作尚未填写密钥。
    @Test func propagatesCredentialStoreFailure() async throws {
        let transport = MiMoRecordingTransport(result: .success(try response(audio: Data())))
        let service = MiMoTTSService(transport: transport, apiKey: { _ in throw MiMoTTSError.keychain(-1) })
        await #expect(throws: MiMoTTSError.keychain(-1)) {
            try await service.audio(engineID: 7, configuration: .init(), text: "测试")
        }
        #expect(await transport.requests.isEmpty)
    }

    /// 认证、额度或服务端错误保留正文，并且不会自动重试计费请求。
    @Test(arguments: [401, 429, 500])
    func reportsHTTPFailureWithoutRetry(status: Int) async throws {
        let failure = HTTPResponse(
            data: Data("{\"error\":{\"message\":\"请求失败\"}}".utf8),
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            finalURL: MiMoTTSConfiguration.endpoint
        )
        let results: [Result<HTTPResponse, any Error>] = [.success(failure), .failure(HTTPClientError.statusResponse(failure))]
        for result in results {
            let transport = MiMoRecordingTransport(result: result)
            let directory = try makeCacheDirectory()
            defer { removeCacheDirectory(directory) }
            let service = HttpTTSService(transport: transport, cache: .init(directory: directory), miMoAPIKey: { _ in "test-key" })
            await #expect(throws: MiMoTTSError.api(status: status, body: failure.decodedText)) {
                try await service.audio(engine: .miMoEngine(), text: "测试", speechRate: 5)
            }
            #expect(await transport.requests.count == 1)
        }
    }

    /// 空结果、缺失音频和错误 Base64 都应解码失败，不能产生可播放的成功结果。
    @Test(arguments: [
        "{\"choices\":[]}",
        "{\"choices\":[{\"message\":{}}]}",
        "{\"choices\":[{\"message\":{\"audio\":{\"data\":\"not-base64!\"}}}]}"
    ])
    func rejectsInvalidAudioResponse(body: String) async throws {
        let response = HTTPResponse(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: MiMoTTSConfiguration.endpoint)
        let transport = MiMoRecordingTransport(result: .success(response))
        let service = MiMoTTSService(transport: transport, apiKey: { _ in "test-key" })
        await #expect(throws: DecodingError.self) {
            try await service.audio(engineID: 7, configuration: .init(), text: "测试")
        }
        #expect(await transport.requests.count == 1)
    }

    /// 导出配置保留渠道音色，密钥读取能力和密钥正文均不进入 JSON。
    @Test func roundTripsChannelWithoutExportingCredentials() throws {
        var engine = HttpTTS.miMoEngine()
        engine.mimo = .init(voice: .moLi)
        let data = try JSONEncoder().encode(engine)
        let decoded = try JSONDecoder().decode(HttpTTS.self, from: data)
        #expect(decoded == engine)
        #expect(decoded.mimo?.voice == .moLi)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("apiKey"))
        #expect(!json.contains("api-key"))
        #expect(MiMoTTSVoice.allCases.count == 9)
    }

    /// 为每个缓存用例创建独立目录，避免用例之间共享音频。
    private func makeCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 清理临时目录，清理失败也记录为测试问题，不静默忽略异常。
    private func removeCacheDirectory(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record(error) }
    }

    /// 生成仅含协议必需字段的响应，验证音频确实从 Base64 解码而非原样播放 JSON。
    private func response(audio: Data) throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["audio": ["data": audio.base64EncodedString()]]]]
        ])
        return HTTPResponse(data: body, statusCode: 200, headers: ["Content-Type": "application/json"], finalURL: MiMoTTSConfiguration.endpoint)
    }
}

/// 记录请求并返回固定结果，使协议用例可检查调用次数及请求正文。
private actor MiMoRecordingTransport: HTTPTransport {
    let result: Result<HTTPResponse, any Error>
    private(set) var requests: [URLRequest] = []

    /// 注入成功响应或明确的网络错误，不依赖真实服务端。
    init(result: Result<HTTPResponse, any Error>) { self.result = result }

    /// 保留每一次调用，以检查渠道不会在错误后自动重复请求。
    func data(for request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try result.get()
    }
}
