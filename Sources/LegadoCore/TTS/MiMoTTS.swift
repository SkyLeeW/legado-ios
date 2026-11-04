import Foundation
import Security

/// MiMo 官方预置音色的标识直接用于请求，避免显示名称与接口取值不一致。
public enum MiMoTTSVoice: String, Codable, CaseIterable, Hashable, Sendable {
    case defaultVoice = "mimo_default"
    case bingTang = "冰糖"
    case moLi = "茉莉"
    case suDa = "苏打"
    case baiHua = "白桦"
    case mia = "Mia"
    case chloe = "Chloe"
    case milo = "Milo"
    case dean = "Dean"

    /// 为默认音色提供中文名称，其余音色保留官方名称。
    public var displayName: String { self == .defaultVoice ? "默认音色" : rawValue }
}

/// MiMo 渠道固定使用官方按量付费接口和 WAV 合成，用户只需选择音色。
public struct MiMoTTSConfiguration: Codable, Hashable, Sendable {
    public static let endpoint = URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!
    public static let model = "mimo-v2.5-tts"
    public var voice: MiMoTTSVoice

    /// 新配置默认使用中文女声冰糖。
    public init(voice: MiMoTTSVoice = .bingTang) { self.voice = voice }
}

public extension HttpTTS {
    /// 创建可直接出现在听书引擎列表中的 MiMo 渠道，内置请求地址和音频类型。
    static func miMoEngine() -> HttpTTS {
        var engine = HttpTTS(name: "小米 MiMo", url: MiMoTTSConfiguration.endpoint.absoluteString)
        engine.mimo = MiMoTTSConfiguration()
        engine.contentType = "audio/wav"
        return engine
    }
}

/// MiMo 的存储与接口错误直接展示给用户，不切换渠道或重复发起合成。
public enum MiMoTTSError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case keychain(OSStatus)
    case api(status: Int, body: String)

    /// 保留错误状态及接口正文，便于定位密钥、额度和服务端问题。
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "请先在小米 MiMo 渠道中填写并保存密钥"
        case .keychain(let status): "MiMo 密钥存储失败（Keychain \(status)）"
        case .api(let status, let body): "MiMo 请求失败（HTTP \(status)）：\(body)"
        }
    }
}

/// 按引擎隔离存储密钥，配置导出与数据库均不包含密钥。
public enum MiMoTTSKeychain {
    /// 读取密钥；尚未配置时返回空值，其余 Keychain 错误正常抛出。
    public static func load(engineID: Int64) throws -> String? {
        var query = itemQuery(engineID: engineID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MiMoTTSError.keychain(status) }
        return String(decoding: result as! Data, as: UTF8.self)
    }

    /// 更新已有密钥或创建新条目，首次解锁后允许后台听书读取。
    public static func save(_ apiKey: String, engineID: Int64) throws {
        var query = itemQuery(engineID: engineID)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(apiKey.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, value in value }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MiMoTTSError.keychain(status) }
    }

    /// 删除渠道时同时移除对应密钥，已不存在的条目无需再次删除。
    public static func delete(engineID: Int64) throws {
        let status = SecItemDelete(itemQuery(engineID: engineID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MiMoTTSError.keychain(status)
        }
    }

    /// 使用固定服务名和引擎编号唯一定位密钥条目。
    private static func itemQuery(engineID: Int64) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.legado.mimo-tts",
            kSecAttrAccount as String: String(engineID)
        ]
    }
}

/// 按 MiMo 官方 Chat Completions 协议发送正文并解码 Base64 WAV 音频。
struct MiMoTTSService: Sendable {
    let transport: any HTTPTransport
    let apiKey: @Sendable (Int64) throws -> String?

    /// 每次合成只请求一次，服务端失败与解析失败均交由听书界面显示。
    func audio(engineID: Int64, configuration: MiMoTTSConfiguration, text: String, timeout: TimeInterval = 300) async throws -> HttpTTSAudio {
        guard let key = try apiKey(engineID) else { throw MiMoTTSError.missingAPIKey }
        try Task.checkCancellation()
        var request = URLRequest(url: MiMoTTSConfiguration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(
            messages: [.init(role: "assistant", content: text)],
            audio: .init(voice: configuration.voice.rawValue)
        ))
        let response: HTTPResponse
        do {
            response = try await transport.data(for: request)
        } catch HTTPClientError.statusResponse(let failure) {
            try Task.checkCancellation()
            throw MiMoTTSError.api(status: failure.statusCode, body: failure.decodedText)
        } catch {
            // 主动停止播放时传播任务取消，不将 URLSession 的取消错误显示成接口失败。
            try Task.checkCancellation()
            throw error
        }
        guard (200...299).contains(response.statusCode) else {
            throw MiMoTTSError.api(status: response.statusCode, body: response.decodedText)
        }
        try Task.checkCancellation()
        let completion = try JSONDecoder().decode(Completion.self, from: response.data)
        return .init(data: completion.audio, contentType: "audio/wav", finalURL: response.finalURL)
    }

    /// 使用类型化请求编码，正文中的引号、换行和反斜杠由 JSONEncoder 正确处理。
    private struct Request: Encodable {
        let model = MiMoTTSConfiguration.model
        let stream = false
        let messages: [Message]
        let audio: Audio

        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Audio: Encodable {
            let format = "wav"
            let voice: String
        }
    }

    /// 从官方响应的首个 choice 中解码音频，缺失字段或非法 Base64 会抛出解码错误。
    private struct Completion: Decodable {
        let audio: Data
        private enum CodingKeys: String, CodingKey { case choices }

        /// 通过容器解码首个结果，空列表按协议解码失败处理。
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            var choices = try values.nestedUnkeyedContainer(forKey: .choices)
            audio = try choices.decode(Choice.self).message.audio.data
        }

        private struct Choice: Decodable {
            let message: Message
            struct Message: Decodable {
                let audio: Audio
                struct Audio: Decodable { let data: Data }
            }
        }
    }
}
