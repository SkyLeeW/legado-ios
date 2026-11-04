@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

/// 音频缓存单位保留原章位置，合成分块不修改阅读器的正文或分页。
struct ReaderHTTPSpeechUnit: Identifiable, Equatable, Sendable {
    let id = UUID()
    let chapterIndex: Int
    let chapterTitle: String
    let position: Int
    let text: String

    /// 按完整字符划分字数、半章或整章，从阅读位置开始保留所有尚未朗读的正文。
    static func make(chapterIndex: Int, title: String, text: String, position: Int, mode: String, characterCount: Int) -> [Self] {
        let characters = Array(text)
        let size: Int
        switch mode {
        case "halfChapter": size = max((characters.count + 1) / 2, 1)
        case "chapter": size = max(characters.count, 1)
        default: size = characterCount
        }
        var units: [Self] = []
        var offset = 0
        for start in stride(from: 0, to: characters.count, by: size) {
            let value = String(characters[start..<min(start + size, characters.count)])
            let end = offset + value.utf16.count
            if end > position {
                let spokenStart = max(offset, position)
                let range = NSRange(location: spokenStart - offset, length: end - spokenStart)
                let spokenText = (value as NSString).substring(with: range)
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    units.append(.init(chapterIndex: chapterIndex, chapterTitle: title, position: spokenStart, text: spokenText))
                }
            }
            offset = end
        }
        return units
    }
}

/// 连续听书使用单一生成队列和滑动缓存窗口，播放器换段不会取消生成任务。
@MainActor
private final class ReaderHTTPSpeechQueue: NSObject, @preconcurrency AVAudioPlayerDelegate {
    /// 本地缓存写入错误不属于渠道故障，不能通过切换渠道重复发起付费合成。
    private struct CacheWriteError: LocalizedError {
        let underlying: Error
        var errorDescription: String? { "保存听书缓存失败：\(underlying.localizedDescription)" }
    }
    private struct Prepared {
        let engine: HttpTTS
        let fileURL: URL
    }
    private let service: HttpTTSService
    private let channels: [HttpTTS]
    private let rate: Int
    private let aheadCount: Int
    private let retriesChannels: Bool
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LegadoSpeech", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var createdDirectory = false
    private var units: [ReaderHTTPSpeechUnit]
    private var index = 0
    private var prepared: [UUID: Prepared] = [:]
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var recoveryTimer: Task<Void, Never>?
    private var failedUntil: [Int64: Date] = [:]
    private var channelErrors: [Int64: String] = [:]
    private var player: AVAudioPlayer?
    private var activeEngine: HttpTTS?
    private var reachedEnd = false
    private var planningError: String?
    private var stopped = false
    private var generationStatus = ""
    private(set) var isPaused = false
    var onStatus: ((String, Bool) -> Void)?
    var onAdvance: ((ReaderHTTPSpeechUnit) -> Void)?
    var onNeedMore: (() -> Void)?
    var onError: ((String?) -> Void)?
    var onFinish: (() -> Void)?

    /// 缓存份数表示当前播放之外的后续份数，所有渠道共享同一个串行生成任务。
    init(service: HttpTTSService, channels: [HttpTTS], rate: Int, aheadCount: Int, retriesChannels: Bool, units: [ReaderHTTPSpeechUnit]) {
        self.service = service
        self.channels = channels
        self.rate = rate
        self.aheadCount = aheadCount
        self.retriesChannels = retriesChannels
        self.units = units
        super.init()
    }

    /// 后续正文不足以覆盖缓存窗口时，请求阅读器继续加载真实章节。
    var needsMoreChapters: Bool { !stopped && !reachedEnd && units.count - index <= aheadCount }

    /// 首次启动仅等待第一份音频，其余缓存会在播放期间按顺序补足。
    func start() {
        recoveryTimer = Task { [weak self] in
            do {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, !self.stopped else { return }
                    if self.recoveryCandidate != nil { self.fillBuffer() }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.onError?(error.localizedDescription)
            }
        }
        playIfReady()
        fillBuffer()
    }

    /// 追加章节只扩展播放计划，已生成和正在生成的音频保持原来的生命周期。
    func append(_ values: [ReaderHTTPSpeechUnit]) {
        units.append(contentsOf: values)
        playIfReady()
        fillBuffer()
    }

    /// 正文加载结束后继续播放已有缓存；加载错误在缓存播放完后保留给用户。
    func finishPlanning(error: String? = nil) {
        reachedEnd = true
        planningError = error
        if let error { onError?(error) }
        playIfReady()
    }

    /// 暂停播放保留缓存窗口，后台生成仍可完成已经计划的后续音频。
    func pause() {
        isPaused = true
        player?.pause()
        publishStatus()
    }

    /// 恢复使用同一个播放器和缓存队列，不重新提交已生成的正文。
    func resume() {
        isPaused = false
        if let player {
            if !player.play() { playbackFailed(CocoaError(.fileReadCorruptFile)) }
        } else {
            playIfReady()
        }
        fillBuffer()
        publishStatus()
    }

    /// 跳段只改变消费位置，生成任务由整次听书会话持有。
    func skip(_ direction: Int) {
        let target = index + direction
        guard units.indices.contains(target) else { return }
        player?.stop()
        player = nil
        worker?.cancel()
        worker = nil
        workerID = UUID()
        index = target
        let end = min(units.count, index + aheadCount + 1)
        let retained = Set(units[index..<end].map(\.id))
        for id in Array(prepared.keys) where !retained.contains(id) {
            removeFile(prepared.removeValue(forKey: id)!.fileURL)
        }
        isPaused = false
        playIfReady()
        fillBuffer()
    }

    /// 停止听书才取消生成和恢复任务，并释放所有未播放的音频。
    func stop() {
        stopped = true
        worker?.cancel()
        recoveryTimer?.cancel()
        player?.stop()
        player = nil
        prepared.removeAll()
        if createdDirectory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { onError?("清理听书临时缓存失败：\(error.localizedDescription)") }
        }
    }

    /// 一个任务按正文顺序填充窗口，渠道恢复后重新准备尚未播放的低优先级缓存。
    private func fillBuffer() {
        guard !stopped, worker == nil else { return }
        let identity = UUID()
        workerID = identity
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.workerID == identity { self.worker = nil } }
            do {
                while !stopped {
                    try Task.checkCancellation()
                    if needsMoreChapters { onNeedMore?() }
                    if let (engine, unit) = recoveryCandidate {
                        try await recover(engine: engine, unit: unit)
                        continue
                    }
                    let end = min(units.count, index + aheadCount + 1)
                    guard let target = (index..<end).first(where: { needsPreparation(at: $0) }) else { break }
                    let unit = units[target]
                    generationStatus = "正在生成\(target == index ? "当前" : "后续第 \(target - index)")份缓存"
                    publishStatus()
                    let value = try await synthesize(unit)
                    try Task.checkCancellation()
                    if target > index || (target == index && player == nil) {
                        if let previous = prepared[unit.id] { removeFile(previous.fileURL) }
                        prepared[unit.id] = value
                    } else {
                        removeFile(value.fileURL)
                    }
                    generationStatus = ""
                    playIfReady()
                }
                publishStatus()
            } catch is CancellationError {
                return
            } catch {
                onError?(error.localizedDescription)
                generationStatus = "音频生成失败：\(error.localizedDescription)"
                publishStatus()
            }
        }
    }

    /// 缺失音频或备用渠道缓存尚未切回已恢复的首选渠道时，需要补充相应缓存。
    private func needsPreparation(at target: Int) -> Bool {
        guard let value = prepared[units[target].id] else { return true }
        guard target > index, let preferred = channels.firstIndex(where: { failedUntil[$0.id] == nil }),
              let actual = channels.firstIndex(where: { $0.id == value.engine.id }) else { return false }
        return preferred < actual
    }

    /// 从高优先级渠道合成；失败保留同一份正文，全部失败则等到明确的重试时间。
    private func synthesize(_ unit: ReaderHTTPSpeechUnit) async throws -> Prepared {
        if !retriesChannels { return try await prepare(engine: channels[0], unit: unit, reload: false) }
        while true {
            try Task.checkCancellation()
            for engine in channels {
                if let date = failedUntil[engine.id], date > Date() { continue }
                do {
                    let value = try await prepare(engine: engine, unit: unit, reload: failedUntil[engine.id] != nil)
                    markHealthy(engine)
                    return value
                } catch let error as CacheWriteError {
                    throw error
                } catch {
                    try Task.checkCancellation()
                    recordFailure(engine, error: error)
                }
            }
            let retry = failedUntil.values.min()!
            generationStatus = "全部渠道暂不可用，\(Int(ceil(max(retry.timeIntervalSinceNow, 0)))) 秒后重试当前缓存"
            publishStatus()
            try await Task.sleep(nanoseconds: UInt64(max(retry.timeIntervalSinceNow, 0) * 1_000_000_000))
        }
    }

    /// 完整音频验证后存入本次会话的磁盘缓存，多份整章音频不同时驻留在播放器内存中。
    private func prepare(engine: HttpTTS, unit: ReaderHTTPSpeechUnit, reload: Bool) async throws -> Prepared {
        let audio = try await service.audio(engine: engine, text: unit.text, speechRate: rate,
                                            cachePolicy: reload ? .reload : .useCache, maximumAttempts: 1)
        try Task.checkCancellation()
        let value = try AVAudioPlayer(data: audio.data)
        guard value.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
        let fileURL = directory.appendingPathComponent(UUID().uuidString + (engine.mimo != nil ? ".wav" : ".audio"))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            createdDirectory = true
            try audio.data.write(to: fileURL, options: .atomic)
            return Prepared(engine: engine, fileURL: fileURL)
        } catch {
            throw CacheWriteError(underlying: error)
        }
    }

    /// 缓存已满且正在使用备用渠道时，使用真实下一份正文恢复高优先级渠道。
    private var recoveryCandidate: (HttpTTS, ReaderHTTPSpeechUnit)? {
        guard !isPaused, player != nil, units.indices.contains(index + 1),
              let activeEngine, let activeIndex = channels.firstIndex(where: { $0.id == activeEngine.id }) else { return nil }
        for engine in channels.prefix(activeIndex) {
            if let date = failedUntil[engine.id], date <= Date() { return (engine, units[index + 1]) }
        }
        return nil
    }

    /// 恢复成功只替换未播放的下一份缓存，当前音频持续播放到结束。
    private func recover(engine: HttpTTS, unit: ReaderHTTPSpeechUnit) async throws {
        do {
            let value = try await prepare(engine: engine, unit: unit, reload: true)
            markHealthy(engine)
            if units.dropFirst(index + 1).contains(where: { $0.id == unit.id }) {
                if let previous = prepared[unit.id] { removeFile(previous.fileURL) }
                prepared[unit.id] = value
            } else {
                removeFile(value.fileURL)
            }
        } catch let error as CacheWriteError {
            throw error
        } catch {
            try Task.checkCancellation()
            recordFailure(engine, error: error)
        }
    }

    /// 记录具体渠道错误及恢复期限，生成失败不会跳过当前正文。
    private func recordFailure(_ engine: HttpTTS, error: Error) {
        failedUntil[engine.id] = Date().addingTimeInterval(60)
        channelErrors[engine.id] = "\(engine.name)：\(error.localizedDescription)"
        onError?(channels.compactMap { channelErrors[$0.id] }.joined(separator: "\n"))
    }

    /// 成功解码后清除该渠道的失败状态，其余渠道错误继续保留。
    private func markHealthy(_ engine: HttpTTS) {
        failedUntil[engine.id] = nil
        channelErrors[engine.id] = nil
        let messages = channels.compactMap { channelErrors[$0.id] }
        onError?(messages.isEmpty ? planningError : messages.joined(separator: "\n"))
    }

    /// 只有真正开始播放才发布正文位置，等待生成时不提前跳页或清除当前文字。
    private func playIfReady() {
        guard !stopped, !isPaused, player == nil else { publishStatus(); return }
        guard units.indices.contains(index) else {
            if reachedEnd { onFinish?() }
            else { onNeedMore?(); publishStatus() }
            return
        }
        guard let value = prepared[units[index].id] else { publishStatus(); return }
        activeEngine = value.engine
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: value.fileURL)
            audioPlayer.delegate = self
            player = audioPlayer
            guard audioPlayer.prepareToPlay(), audioPlayer.play() else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            playbackFailed(error)
            return
        }
        onAdvance?(units[index])
        publishStatus()
    }

    /// 播放失败从同一份正文重新选择渠道，不触发下一段或下一章的进度。
    private func playbackFailed(_ error: Error) {
        recordFailure(activeEngine!, error: error)
        player?.stop()
        player = nil
        if let value = prepared[units[index].id] { removeFile(value.fileURL) }
        prepared[units[index].id] = nil
        fillBuffer()
        publishStatus()
    }

    /// 播放结束立即衔接下一份已验证的音频文件，再异步补充缓存窗口。
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player, !stopped else { return }
        if !flag { playbackFailed(CocoaError(.fileReadCorruptFile)); return }
        self.player = nil
        removeFile(prepared[units[index].id]!.fileURL)
        prepared[units[index].id] = nil
        index += 1
        playIfReady()
        fillBuffer()
    }

    /// 已消费或被恢复渠道替换的文件及时删除，清理失败明确显示而不隐藏错误。
    private func removeFile(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { onError?("清理听书临时缓存失败：\(error.localizedDescription)") }
    }

    /// 状态区分播放、暂停、等待正文和等待合成，并显示真实已完成的后续缓存份数。
    private func publishStatus() {
        guard !stopped else { return }
        let ready = units.dropFirst(index + 1).filter { prepared[$0.id] != nil }.count
        let state = isPaused ? "已暂停" : (player != nil ? "播放中" : "等待音频")
        let channel = activeEngine.map { " · \($0.name)" } ?? ""
        let loading = generationStatus.isEmpty ? "" : " · \(generationStatus)"
        onStatus?("\(state)\(channel) · 已缓存 \(ready)/\(aheadCount) 份\(loading)", !isPaused && player == nil)
    }
}

private final class IncrementalAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.legado.tts.stream-loader")
    private let contentType: String?
    private let expectedLength: Int64
    private var data = Data()
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var finished = false
    private var failure: Error?
    private var consumeTask: Task<Void, Never>?

    init(stream: HttpTTSAudioStream) {
        contentType = stream.contentType
        expectedLength = stream.expectedContentLength ?? 0
        super.init()
        consumeTask = Task { [weak self] in
            do {
                for try await chunk in stream.chunks {
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        self?.data.append(chunk)
                        self?.processPendingRequests()
                    }
                }
                self?.queue.async { [weak self] in
                    self?.finished = true
                    self?.processPendingRequests()
                }
            } catch {
                self?.queue.async { [weak self] in
                    self?.failure = error
                    self?.finished = true
                    self?.processPendingRequests()
                }
            }
        }
    }

    deinit { consumeTask?.cancel() }

    func cancel() {
        consumeTask?.cancel()
        queue.async { [weak self] in
            guard let self, !finished else { return }
            failure = CancellationError()
            finished = true
            processPendingRequests()
        }
    }

    func install(on asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        pending.append(loadingRequest)
        processPendingRequests()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pending.removeAll { $0 === loadingRequest }
    }

    private func processPendingRequests() {
        pending.removeAll { request in
            if let info = request.contentInformationRequest {
                info.contentType = contentType.flatMap { UTType(mimeType: $0)?.identifier }
                info.contentLength = expectedLength
                info.isByteRangeAccessSupported = false
            }
            if let failure {
                request.finishLoading(with: failure)
                return true
            }
            guard let dataRequest = request.dataRequest else {
                if finished { request.finishLoading(); return true }
                return false
            }
            let offset = max(Int(dataRequest.currentOffset), Int(dataRequest.requestedOffset))
            if offset < data.count {
                let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
                let end = min(data.count, requestedEnd)
                if end > offset { dataRequest.respond(with: data.subdata(in: offset..<end)) }
            }
            let deliveredEnd = max(Int(dataRequest.currentOffset), Int(dataRequest.requestedOffset))
            let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
            if deliveredEnd >= requestedEnd || finished {
                request.finishLoading()
                return true
            }
            return false
        }
    }
}

@MainActor
final class ReaderSpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionCount = 0
    @Published private(set) var currentSegmentIndex = 0
    @Published private(set) var channelStatus = ""
    @Published private(set) var currentHTTPUnit: ReaderHTTPSpeechUnit?
    @Published private(set) var isBuffering = false
    private var continuousHTTPQueue: ReaderHTTPSpeechQueue?
    var onNeedHTTPChapters: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private let httpService = HttpTTSService()
    private var audioPlayer: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var streamLoader: IncrementalAudioResourceLoader?
    private var streamCompletionToken: NSObjectProtocol?
    private var httpTask: Task<Void, Never>?
    /// 下一段音频由独立任务持有，自动翻页时将任务交给播放请求继续等待。
    private struct HTTPPreparation: Sendable {
        let engine: HttpTTS
        let text: String
        let rate: Int
        let task: Task<HttpTTSAudio, Error>
    }
    private var httpPreparation: HTTPPreparation?
    private var httpPreparationObserver: Task<Void, Never>?
    private var httpContinuationText: String?
    private var httpSegments: [String] = []
    private var httpSegmentIndex = 0
    private var httpEngine: HttpTTS?
    private var httpCachePolicy: HttpTTSCachePolicy = .useCache
    private var configuredBackupEngines: [HttpTTS] = []
    private var usesChannelFailover = false
    private var httpChannels: [HttpTTS] = []
    private var failedChannels: [Int64: Date] = [:]
    private var channelErrors: [Int64: String] = [:]
    private var channelFailureVersions: [Int64: UUID] = [:]
    private var recoveryTask: Task<Void, Never>?
    private var httpSession = UUID()
    /// 异步加载下一章正文时，用会话标识排除已经停止或换书的请求。
    var httpSessionID: UUID { httpSession }
    private var isRoutingChannels = false
    private let recoveryInterval: TimeInterval = 60
    private var systemSegments: [String] = []
    private var systemSegmentIndex = 0
    private var segmentIndexOffset = 0
    private var followsSystemRate = true
    private var speechRate = 5
    private var readByPage = false
    private var streamsHTTPAudio = true
    private var voiceIdentifier = ""
    private var continuesAcrossChapters = false
    private var notificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var resumesAfterInterruption = false
    private var isChangingSystemSegment = false
    private var ignoresAudioFocus = false
    private var pausesForPhoneCalls = false
    private var mediaButtonPerNext = false
    private var bookName = ""
    private var chapterTitle = ""
    private var author = ""
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onRemoteStop: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        observeAudioSession()
        installRemoteCommands()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        remoteCommandTargets.forEach { command, target in command.removeTarget(target) }
    }

    func toggle(text: String, continuesAcrossChapters: Bool = false) {
        if isSpeaking || isPaused {
            stop()
            return
        }
        speak(text, continuesAcrossChapters: continuesAcrossChapters)
    }

    func toggleHTTP(engine: HttpTTS, text: String, continuesAcrossChapters: Bool = false) {
        if isSpeaking || isPaused {
            stop()
            return
        }
        speakHTTP(engine: engine, text: text, continuesAcrossChapters: continuesAcrossChapters)
    }

    /// 停止当前播放；只有自然续读才保留已经准备的下一段音频。
    func stop(preservingHTTPPreparation: Bool = false) {
        // 换书、停止和关闭页面时作废当前会话，取消请求与恢复探测。
        httpSession = UUID()
        continuousHTTPQueue?.stop()
        continuousHTTPQueue = nil
        currentHTTPUnit = nil
        isBuffering = false
        recoveryTask?.cancel()
        recoveryTask = nil
        httpChannels = []
        isRoutingChannels = false
        channelStatus = ""
        synthesizer.stopSpeaking(at: .word)
        audioPlayer?.stop()
        audioPlayer = nil
        streamPlayer?.pause()
        streamLoader?.cancel()
        streamPlayer = nil
        streamLoader = nil
        if let streamCompletionToken {
            NotificationCenter.default.removeObserver(streamCompletionToken)
            self.streamCompletionToken = nil
        }
        httpTask?.cancel()
        httpTask = nil
        if !preservingHTTPPreparation { cancelHTTPPreparation() }
        httpContinuationText = nil
        httpSegments = []
        httpSegmentIndex = 0
        httpEngine = nil
        systemSegments = []
        systemSegmentIndex = 0
        segmentIndexOffset = 0
        continuesAcrossChapters = false
        isSpeaking = false
        isPaused = false
        updateNowPlaying()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func configure(
        followsSystemRate: Bool,
        speechRate: Int,
        readByPage: Bool,
        streamsHTTPAudio: Bool = true,
        voiceIdentifier: String = "",
        ignoresAudioFocus: Bool = false,
        pausesForPhoneCalls: Bool = false,
        mediaButtonPerNext: Bool = false,
        bookName: String = "",
        chapterTitle: String = "",
        author: String = "",
        usesChannelFailover: Bool = false,
        backupEngines: [HttpTTS] = []
    ) {
        self.followsSystemRate = followsSystemRate
        self.speechRate = min(max(speechRate, 0), 45)
        self.readByPage = readByPage
        self.streamsHTTPAudio = streamsHTTPAudio
        self.voiceIdentifier = voiceIdentifier
        self.ignoresAudioFocus = ignoresAudioFocus
        self.pausesForPhoneCalls = pausesForPhoneCalls
        self.mediaButtonPerNext = mediaButtonPerNext
        self.bookName = bookName
        self.chapterTitle = chapterTitle
        self.author = author
        self.usesChannelFailover = usesChannelFailover
        configuredBackupEngines = backupEngines
    }

    func speak(_ text: String, continuesAcrossChapters: Bool = false, segmentIndexOffset: Int = 0) {
        stop()
        errorMessage = nil
        activateAudioSession()
        self.continuesAcrossChapters = continuesAcrossChapters
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        systemSegments = segments(for: text)
        guard !systemSegments.isEmpty else { return }
        systemSegmentIndex = 0
        self.segmentIndexOffset = max(segmentIndexOffset, 0)
        playCurrentSystemSegment()
    }

    /// 开始所选渠道的分段朗读，配置试听可指定重新请求以验证密钥。
    func speakHTTP(
        engine: HttpTTS,
        text: String,
        continuesAcrossChapters: Bool = false,
        segmentIndexOffset: Int = 0,
        cachePolicy: HttpTTSCachePolicy = .useCache,
        nextText: String? = nil
    ) {
        stop(preservingHTTPPreparation: true)
        errorMessage = nil
        activateAudioSession()
        self.continuesAcrossChapters = continuesAcrossChapters
        httpEngine = engine
        httpCachePolicy = cachePolicy
        // 试听强制验证指定渠道，日常听书才启用用户选择的备用渠道。
        if case .useCache = cachePolicy, usesChannelFailover {
            isRoutingChannels = true
            httpChannels = [engine] + configuredBackupEngines.filter { $0.id != engine.id }
        }
        httpSegments = segments(for: text)
        guard !httpSegments.isEmpty else {
            cancelHTTPPreparation()
            return
        }
        httpContinuationText = nextText
        // 仅保留与新正文、渠道配置及语速完全一致的预生成任务，试听始终重新请求。
        if let preparation = httpPreparation {
            let channels = isRoutingChannels ? httpChannels : [engine]
            if case .reload = cachePolicy {
                cancelHTTPPreparation()
            } else if preparation.text != httpSegments[0]
                || preparation.rate != speechRate + 5
                || !channels.contains(preparation.engine) {
                cancelHTTPPreparation()
            }
        }
        httpSegmentIndex = 0
        self.segmentIndexOffset = max(segmentIndexOffset, 0)
        isSpeaking = true
        if isRoutingChannels { startChannelRecovery() }
        playCurrentHTTPSegment()
    }

    /// 下一章正文只保留首段，等本章末段开始播放后再生成，避免提前合成整章。
    func prepareHTTPContinuation(text: String) {
        httpContinuationText = segments(for: text).first
        if audioPlayer != nil || streamPlayer != nil { prepareNextHTTPAudio() }
    }

    /// 在线听书以章节缓存单位连续播放，屏幕翻页不再结束或重建音频会话。
    func speakHTTPContinuously(engine: HttpTTS, units: [ReaderHTTPSpeechUnit], aheadCount: Int) {
        stop()
        errorMessage = nil
        activateAudioSession()
        let channels = usesChannelFailover
            ? [engine] + configuredBackupEngines.filter { $0.id != engine.id } : [engine]
        let queue = ReaderHTTPSpeechQueue(service: httpService, channels: channels, rate: speechRate + 5,
                                         aheadCount: aheadCount, retriesChannels: usesChannelFailover, units: units)
        continuousHTTPQueue = queue
        queue.onStatus = { [weak self, weak queue] status, buffering in
            guard let self, let queue else { return }
            self.channelStatus = status
            self.isBuffering = buffering
            self.isPaused = queue.isPaused
            self.isSpeaking = !queue.isPaused
            self.updateNowPlaying()
        }
        queue.onAdvance = { [weak self] unit in
            self?.chapterTitle = unit.chapterTitle
            self?.currentHTTPUnit = unit
            self?.updateNowPlaying()
        }
        queue.onNeedMore = { [weak self] in self?.onNeedHTTPChapters?() }
        queue.onError = { [weak self] error in self?.errorMessage = error }
        queue.onFinish = { [weak self] in self?.stop() }
        queue.start()
    }

    /// 阅读器按缓存窗口补充章节，队列会在已有音频播放时继续合成。
    func appendHTTPUnits(_ units: [ReaderHTTPSpeechUnit]) { continuousHTTPQueue!.append(units) }

    /// 标记真实书尾或正文加载错误，避免把加载失败当作可以跳过的空章节。
    func finishHTTPPlanning(error: String? = nil) { continuousHTTPQueue!.finishPlanning(error: error) }

    /// 此状态只决定是否需要更多章节正文，不把尚未完成的网络请求算作缓存。
    var needsMoreHTTPChapters: Bool { continuousHTTPQueue?.needsMoreChapters == true }

    /// 连续缓存模式独立于系统朗读的按页和按段回调。
    var isUsingHTTPQueue: Bool { continuousHTTPQueue != nil }

    func pauseOrResume(text: String, continuesAcrossChapters: Bool = false) {
        if isPaused {
            resumePlayback()
        } else if isSpeaking {
            pausePlayback()
        } else {
            speak(text, continuesAcrossChapters: continuesAcrossChapters)
        }
    }

    func pauseOrResumeHTTP(engine: HttpTTS, text: String, continuesAcrossChapters: Bool = false) {
        if isPaused {
            resumePlayback()
        } else if isSpeaking {
            pausePlayback()
        } else {
            speakHTTP(engine: engine, text: text, continuesAcrossChapters: continuesAcrossChapters)
        }
    }

    private func segments(for text: String) -> [String] {
        let values = readByPage ? [text] : text.components(separatedBy: .newlines)
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: ignoresAudioFocus ? [.mixWithOthers] : [])
        try? session.setActive(true)
    }

    private func pausePlayback() {
        if let continuousHTTPQueue {
            continuousHTTPQueue.pause()
            return
        }
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.pause()
        } else if let streamPlayer {
            streamPlayer.pause()
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        } else if httpTask != nil {
            httpTask?.cancel()
            httpTask = nil
        } else {
            return
        }
        isPaused = true
        isSpeaking = false
        recoveryTask?.cancel()
        recoveryTask = nil
        updateNowPlaying()
    }

    private func resumePlayback() {
        activateAudioSession()
        if let continuousHTTPQueue {
            continuousHTTPQueue.resume()
            return
        }
        if let audioPlayer {
            isSpeaking = audioPlayer.play()
        } else if let streamPlayer {
            streamPlayer.play()
            isSpeaking = true
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isSpeaking = true
        } else if httpEngine != nil, httpSegments.indices.contains(httpSegmentIndex) {
            isSpeaking = true
            playCurrentHTTPSegment()
        } else {
            return
        }
        isPaused = false
        if isRoutingChannels, recoveryTask == nil { startChannelRecovery() }
        updateNowPlaying()
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleAudioInterruption(type: type, options: options) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        })
    }

    private func handleAudioInterruption(type raw: UInt?, options rawOptions: UInt) {
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            resumesAfterInterruption = isSpeaking
            if isSpeaking { pausePlayback() }
        case .ended:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if resumesAfterInterruption, options.contains(.shouldResume) { resumePlayback() }
            resumesAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason raw: UInt?) {
        guard let raw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        if isSpeaking { pausePlayback() }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        addRemoteTarget(center.playCommand) { $0.resumePlayback() }
        addRemoteTarget(center.pauseCommand) { $0.pausePlayback() }
        addRemoteTarget(center.togglePlayPauseCommand) { controller in
            controller.isPaused ? controller.resumePlayback() : controller.pausePlayback()
        }
        addRemoteTarget(center.stopCommand) { controller in
            controller.stop()
            controller.onRemoteStop?()
        }
        addRemoteTarget(center.nextTrackCommand) { $0.skipForward(usesChapterPreference: true) }
        addRemoteTarget(center.previousTrackCommand) { $0.skipBackward(usesChapterPreference: true) }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, action: @escaping @MainActor (ReaderSpeechController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    func nextSegment() {
        guard isSpeaking || isPaused else { return }
        skipForward(usesChapterPreference: false)
    }

    func previousSegment() {
        guard isSpeaking || isPaused else { return }
        skipBackward(usesChapterPreference: false)
    }

    private func playCurrentSystemSegment() {
        guard systemSegments.indices.contains(systemSegmentIndex) else {
            finishNaturally()
            return
        }
        let utterance = AVSpeechUtterance(string: systemSegments[systemSegmentIndex])
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let multiplier = followsSystemRate ? 1 : Float(speechRate + 5) / 10
        utterance.rate = min(
            max(AVSpeechUtteranceDefaultSpeechRate * multiplier, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
        utterance.pitchMultiplier = 1
        synthesizer.speak(utterance)
        currentSegmentIndex = segmentIndexOffset + systemSegmentIndex
        isSpeaking = true
        isPaused = false
        updateNowPlaying()
    }

    private func skipForward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onNextChapter?()
        } else if let continuousHTTPQueue {
            continuousHTTPQueue.skip(1)
        } else if httpEngine != nil, httpSegmentIndex + 1 < httpSegments.count {
            stopCurrentHTTPPlayback()
            httpSegmentIndex += 1
            playCurrentHTTPSegment()
        } else if !systemSegments.isEmpty, systemSegmentIndex + 1 < systemSegments.count {
            changeSystemSegment(to: systemSegmentIndex + 1)
        } else {
            onNextChapter?()
        }
    }

    private func skipBackward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onPreviousChapter?()
        } else if let continuousHTTPQueue {
            continuousHTTPQueue.skip(-1)
        } else if httpEngine != nil, httpSegmentIndex > 0 {
            stopCurrentHTTPPlayback()
            httpSegmentIndex -= 1
            playCurrentHTTPSegment()
        } else if !systemSegments.isEmpty, systemSegmentIndex > 0 {
            changeSystemSegment(to: systemSegmentIndex - 1)
        } else {
            onPreviousChapter?()
        }
    }

    private func stopCurrentHTTPPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        streamPlayer?.pause()
        streamLoader?.cancel()
        streamPlayer = nil
        streamLoader = nil
        if let streamCompletionToken {
            NotificationCenter.default.removeObserver(streamCompletionToken)
            self.streamCompletionToken = nil
        }
        httpTask?.cancel()
        httpTask = nil
    }

    private func changeSystemSegment(to index: Int) {
        isChangingSystemSegment = true
        synthesizer.stopSpeaking(at: .immediate)
        systemSegmentIndex = index
        playCurrentSystemSegment()
        DispatchQueue.main.async { [weak self] in self?.isChangingSystemSegment = false }
    }

    private func updateNowPlaying() {
        guard isSpeaking || isPaused else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookName,
            MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyPlaybackRate: isSpeaking ? 1 : 0
        ]
    }

    private func playCurrentHTTPSegment() {
        if isRoutingChannels {
            playRoutedHTTPSegment()
            return
        }
        guard let engine = httpEngine, httpSegments.indices.contains(httpSegmentIndex) else {
            stop()
            return
        }
        let text = httpSegments[httpSegmentIndex]
        let session = httpSession
        currentSegmentIndex = segmentIndexOffset + httpSegmentIndex
        let rate = speechRate + 5
        httpTask?.cancel()
        httpTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let preparation = takeHTTPPreparation(engine: engine, text: text) {
                    let audio = try await preparedHTTPAudio(preparation)
                    try Task.checkCancellation()
                    try playBufferedHTTPAudio(audio.data)
                } else if streamsHTTPAudio {
                    let stream = try await httpService.audioStream(engine: engine, text: text, speechRate: rate, cachePolicy: httpCachePolicy)
                    try Task.checkCancellation()
                    if stream.isIncremental, stream.expectedContentLength ?? 0 > 0 {
                        playIncrementalHTTPStream(stream)
                    } else {
                        var data = Data()
                        for try await chunk in stream.chunks { data.append(chunk) }
                        try Task.checkCancellation()
                        try playBufferedHTTPAudio(data)
                    }
                } else {
                    let audio = try await httpService.audio(engine: engine, text: text, speechRate: rate, cachePolicy: httpCachePolicy)
                    try Task.checkCancellation()
                    try playBufferedHTTPAudio(audio.data)
                }
                guard session == httpSession else { return }
                isPaused = false
                updateNowPlaying()
                if !isSpeaking { throw CocoaError(.fileReadCorruptFile) }
                prepareNextHTTPAudio()
            } catch is CancellationError {
                return
            } catch {
                // 已取消或属于旧页面的请求不能停止后来启动的播放。
                guard !Task.isCancelled, session == httpSession else { return }
                errorMessage = error.localizedDescription
                stop()
            }
        }
    }

    /// 只有播放器确认能开始播放时才将该段标记为播放中。
    private func playBufferedHTTPAudio(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        guard player.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
        audioPlayer = player
        guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
        isSpeaking = true
    }

    private func playIncrementalHTTPStream(_ stream: HttpTTSAudioStream) {
        let url = URL(string: "legado-tts-stream://audio/\(UUID().uuidString)")!
        let asset = AVURLAsset(url: url)
        let loader = IncrementalAudioResourceLoader(stream: stream)
        loader.install(on: asset)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        streamLoader = loader
        streamPlayer = player
        streamCompletionToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.incrementalPlayerDidFinish() }
        }
        player.play()
        isSpeaking = true
    }

    private func incrementalPlayerDidFinish() {
        stopCurrentHTTPPlayback()
        httpSegmentIndex += 1
        if httpSegmentIndex < httpSegments.count { playCurrentHTTPSegment() }
        else { finishNaturally() }
    }

    /// 优先取当前章的下一段，末段则使用阅读页提供的下一页或下一章首段。
    private var nextHTTPText: String? {
        let nextIndex = httpSegmentIndex + 1
        return httpSegments.indices.contains(nextIndex) ? httpSegments[nextIndex] : httpContinuationText
    }

    /// 播放当前段时只提前生成下一段，MiMo 和自动切换渠道采用相同的有界预读规则。
    private func prepareNextHTTPAudio() {
        guard let engine = httpEngine, let text = nextHTTPText,
              case .useCache = httpCachePolicy else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rate = speechRate + 5
        if let preparation = httpPreparation,
           preparation.engine == engine, preparation.text == normalized, preparation.rate == rate { return }
        cancelHTTPPreparation()
        let service = httpService
        let attempts = isRoutingChannels ? 1 : 6
        let task = Task {
            try Task.checkCancellation()
            return try await service.audio(engine: engine, text: normalized, speechRate: rate, maximumAttempts: attempts)
        }
        httpPreparation = HTTPPreparation(engine: engine, text: normalized, rate: rate, task: task)
        let session = httpSession
        httpPreparationObserver = Task { [weak self] in
            do {
                _ = try await task.value
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, session == self.httpSession else { return }
                self.errorMessage = "\(engine.name) 下一段预生成失败：\(error.localizedDescription)"
            }
        }
    }

    /// 播放请求取得任务所有权，尚未完成的预生成会继续等待，不会再次向渠道提交相同文本。
    private func takeHTTPPreparation(engine: HttpTTS, text: String) -> HTTPPreparation? {
        guard let preparation = httpPreparation,
              preparation.engine == engine, preparation.text == text,
              preparation.rate == speechRate + 5 else { return nil }
        httpPreparation = nil
        httpPreparationObserver?.cancel()
        httpPreparationObserver = nil
        return preparation
    }

    /// 播放等待被停止或跳段取消时，同时取消已经接管的合成请求。
    private func preparedHTTPAudio(_ preparation: HTTPPreparation) async throws -> HttpTTSAudio {
        try await withTaskCancellationHandler {
            try await preparation.task.value
        } onCancel: {
            preparation.task.cancel()
        }
    }

    /// 用户停止或改变阅读目标时取消预生成，避免继续请求不再收听的正文。
    private func cancelHTTPPreparation() {
        httpPreparation?.task.cancel()
        httpPreparation = nil
        httpPreparationObserver?.cancel()
        httpPreparationObserver = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        audioPlayer = nil
        guard flag else {
            if isRoutingChannels, let engine = httpEngine {
                recordChannelFailure(engine, error: CocoaError(.fileReadCorruptFile))
                playCurrentHTTPSegment()
                return
            }
            errorMessage = "HTTP TTS 音频播放失败"
            stop()
            return
        }
        httpSegmentIndex += 1
        if httpSegmentIndex < httpSegments.count {
            playCurrentHTTPSegment()
        } else {
            finishNaturally()
        }
    }

    /// 渠道失败进入定时重试状态，保留明确错误供设置页面查看。
    private func recordChannelFailure(_ engine: HttpTTS, error: Error) {
        failedChannels[engine.id] = Date().addingTimeInterval(recoveryInterval)
        channelFailureVersions[engine.id] = UUID()
        channelErrors[engine.id] = "\(engine.name)：\(error.localizedDescription)"
        errorMessage = httpChannels.compactMap { channelErrors[$0.id] }.joined(separator: "\n")
        channelStatus = "\(engine.name) 失败，正在切换渠道"
    }

    /// 始终从优先级最高的可用渠道合成当前段，全不可用时按恢复时间等待后继续。
    private func playRoutedHTTPSegment() {
        let index = httpSegmentIndex
        let text = httpSegments[index]
        let session = httpSession
        currentSegmentIndex = segmentIndexOffset + index
        httpTask?.cancel()
        httpTask = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try Task.checkCancellation()
                    for engine in httpChannels {
                        if let nextRetry = failedChannels[engine.id], nextRetry > Date() { continue }
                        do {
                            channelStatus = "正在使用 \(engine.name)"
                            let audio: HttpTTSAudio
                            if let preparation = takeHTTPPreparation(engine: engine, text: text) {
                                audio = try await preparedHTTPAudio(preparation)
                            } else {
                                audio = try await httpService.audio(
                                    engine: engine, text: text, speechRate: speechRate + 5,
                                    cachePolicy: failedChannels[engine.id] == nil ? .useCache : .reload,
                                    maximumAttempts: 1
                                )
                            }
                            try Task.checkCancellation()
                            guard session == httpSession else { return }
                            try playBufferedHTTPAudio(audio.data)
                            failedChannels[engine.id] = nil
                            channelErrors[engine.id] = nil
                            channelFailureVersions[engine.id] = UUID()
                            httpEngine = engine
                            channelStatus = "当前渠道：\(engine.name)"
                            errorMessage = httpChannels.compactMap { channelErrors[$0.id] }.joined(separator: "\n")
                            if errorMessage == "" { errorMessage = nil }
                            isPaused = false
                            updateNowPlaying()
                            prepareNextHTTPAudio()
                            return
                        } catch {
                            try Task.checkCancellation()
                            guard session == httpSession else { return }
                            audioPlayer?.stop()
                            audioPlayer = nil
                            recordChannelFailure(engine, error: error)
                        }
                    }
                    channelStatus = "全部渠道暂不可用，等待自动重试"
                    // 每次请求结束都会更新失败期限，避免对失效渠道无间隔循环请求。
                    let nextRetry = httpChannels.compactMap { failedChannels[$0.id] }.min()!
                    let delay = max(nextRetry.timeIntervalSinceNow, 0)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                stop()
            }
        }
    }

    /// 播放备用渠道期间探测失败的更高优先级渠道，恢复结果仅在下一段选择时生效。
    private func startChannelRecovery() {
        let session = httpSession
        recoveryTask = Task { [weak self] in
            do {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, session == self.httpSession else { return }
                    if self.isPaused || self.audioPlayer == nil { continue }
                    let activeIndex = self.httpChannels.firstIndex { $0.id == self.httpEngine?.id }!
                    for engine in self.httpChannels.prefix(activeIndex) {
                        guard let nextRetry = self.failedChannels[engine.id], nextRetry <= Date() else { continue }
                        // 用真实下一段探测并写入缓存，切回时可以直接播放，避免额外合成测试文本。
                        guard let text = self.nextHTTPText else { break }
                        let version = self.channelFailureVersions[engine.id]
                        self.failedChannels[engine.id] = Date().addingTimeInterval(self.recoveryInterval)
                        do {
                            let audio = try await self.httpService.audio(
                                engine: engine, text: text, speechRate: self.speechRate + 5,
                                cachePolicy: .reload, maximumAttempts: 1
                            )
                            try Task.checkCancellation()
                            guard session == self.httpSession else { return }
                            // 若播放请求期间记录了新的失败，本次旧探测无权覆盖较新的渠道状态。
                            if version != self.channelFailureVersions[engine.id] { continue }
                            let player = try AVAudioPlayer(data: audio.data)
                            guard player.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
                            self.failedChannels[engine.id] = nil
                            self.channelErrors[engine.id] = nil
                            self.channelFailureVersions[engine.id] = UUID()
                            self.errorMessage = self.httpChannels.compactMap { self.channelErrors[$0.id] }.joined(separator: "\n")
                            if self.errorMessage == "" { self.errorMessage = nil }
                            self.channelStatus = "\(engine.name) 已恢复，将在下一段切回"
                        } catch {
                            try Task.checkCancellation()
                            guard session == self.httpSession else { return }
                            if version != self.channelFailureVersions[engine.id] { continue }
                            self.recordChannelFailure(engine, error: error)
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func finishNaturally() {
        let shouldContinue = continuesAcrossChapters
        stop(preservingHTTPPreparation: shouldContinue)
        if shouldContinue { completionCount += 1 }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !isChangingSystemSegment else { return }
        systemSegmentIndex += 1
        if systemSegmentIndex < systemSegments.count { playCurrentSystemSegment() }
        else { finishNaturally() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard !isChangingSystemSegment else { return }
        guard !synthesizer.isSpeaking else { return }
        isSpeaking = false
        isPaused = false
        updateNowPlaying()
    }
}
