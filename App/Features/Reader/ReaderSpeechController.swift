@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

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
    private let synthesizer = AVSpeechSynthesizer()
    private let httpService = HttpTTSService()
    private var audioPlayer: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var streamLoader: IncrementalAudioResourceLoader?
    private var streamCompletionToken: NSObjectProtocol?
    private var httpTask: Task<Void, Never>?
    private var httpPrefetchTasks: [Task<Void, Never>] = []
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

    func stop() {
        // 换书、停止和关闭页面时作废当前会话，取消请求与恢复探测。
        httpSession = UUID()
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
        httpPrefetchTasks.forEach { $0.cancel() }
        httpPrefetchTasks.removeAll()
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
        cachePolicy: HttpTTSCachePolicy = .useCache
    ) {
        stop()
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
        guard !httpSegments.isEmpty else { return }
        httpSegmentIndex = 0
        self.segmentIndexOffset = max(segmentIndexOffset, 0)
        isSpeaking = true
        if isRoutingChannels { startChannelRecovery() }
        playCurrentHTTPSegment()
        prefetchHTTP(engine: engine, texts: Array(httpSegments.dropFirst()))
    }

    func prefetchHTTP(engine: HttpTTS, text: String, limit: Int = 10) {
        let values = Array(segments(for: text).prefix(max(limit, 0)))
        prefetchHTTP(engine: engine, texts: values)
    }

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
        currentSegmentIndex = segmentIndexOffset + httpSegmentIndex
        let rate = speechRate + 5
        httpTask?.cancel()
        httpTask = Task { [weak self] in
            guard let self else { return }
            do {
                if streamsHTTPAudio {
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
                isPaused = false
                updateNowPlaying()
                if !isSpeaking { throw CocoaError(.fileReadCorruptFile) }
            } catch is CancellationError {
                return
            } catch {
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

    /// 仅对允许预读的渠道请求后续段落，MiMo 始终按播放需求合成。
    private func prefetchHTTP(engine: HttpTTS, texts: [String]) {
        // MiMo 按实际播放段落合成，不对未收听内容发起计费请求。
        if engine.mimo != nil { return }
        if usesChannelFailover { return }
        guard !texts.isEmpty else { return }
        let rate = speechRate + 5
        let task = Task { [weak self] in
            guard let self else { return }
            for text in texts {
                guard !Task.isCancelled else { return }
                _ = try? await self.httpService.audio(engine: engine, text: text, speechRate: rate)
            }
        }
        httpPrefetchTasks.append(task)
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
                            let audio = try await httpService.audio(
                                engine: engine, text: text, speechRate: speechRate + 5,
                                cachePolicy: failedChannels[engine.id] == nil ? .useCache : .reload,
                                maximumAttempts: 1, timeout: 20
                            )
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
                        let nextIndex = self.httpSegmentIndex + 1
                        if nextIndex >= self.httpSegments.count { break }
                        let text = self.httpSegments[nextIndex]
                        let version = self.channelFailureVersions[engine.id]
                        self.failedChannels[engine.id] = Date().addingTimeInterval(self.recoveryInterval)
                        do {
                            let audio = try await self.httpService.audio(
                                engine: engine, text: text, speechRate: self.speechRate + 5,
                                cachePolicy: .reload, maximumAttempts: 1, timeout: 20
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
        stop()
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
