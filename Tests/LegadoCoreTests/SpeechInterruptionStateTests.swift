import Testing
@testable import LegadoCore

struct SpeechInterruptionStateTests {
    /// 导航中断正在播放的听书后，系统允许恢复时应且只应续播一次。
    @Test func resumesPlaybackOnceAfterNavigation() {
        var state = SpeechInterruptionState()
        let pauses = state.begin(wasPlaying: true)
        let resumes = state.end(allowsResume: true)
        let resumesAgain = state.end(allowsResume: true)
        #expect(pauses)
        #expect(resumes)
        #expect(!resumesAgain)
    }

    /// 重复收到中断开始事件时，已经暂停的状态不能覆盖最初的播放意图。
    @Test func repeatedBeginningsKeepTheOriginalPlaybackIntent() {
        var state = SpeechInterruptionState()
        let pauses = state.begin(wasPlaying: true)
        let pausesAgain = state.begin(wasPlaying: false)
        let pausesThirdTime = state.begin(wasPlaying: false)
        let resumes = state.end(allowsResume: true)
        #expect(pauses)
        #expect(!pausesAgain)
        #expect(!pausesThirdTime)
        #expect(resumes)
    }

    /// 用户原本就没有播放时，导航结束不能擅自启动听书。
    @Test func previouslyPausedPlaybackDoesNotStart() {
        var state = SpeechInterruptionState()
        let pauses = state.begin(wasPlaying: false)
        let resumes = state.end(allowsResume: true)
        #expect(!pauses)
        #expect(!resumes)
    }

    /// 导航期间用户主动暂停或停止后，系统恢复通知不能重新启动音频。
    @Test func manualPauseOrStopCancelsAutomaticResume() {
        var state = SpeechInterruptionState()
        _ = state.begin(wasPlaying: true)
        state.cancelResume()
        let resumes = state.end(allowsResume: true)
        #expect(!resumes)
    }

    /// 用户取消后到达的重复开始通知不能重新登记旧的自动续播意图。
    @Test func duplicateEventsCannotUndoManualCancellation() {
        var state = SpeechInterruptionState()
        _ = state.begin(wasPlaying: true)
        state.cancelResume()
        _ = state.begin(wasPlaying: true)
        let resumes = state.end(allowsResume: true)
        #expect(!resumes)
    }

    /// 系统没有允许恢复时保持暂停，重复结束通知也不能绕过这个决定。
    @Test func systemDenialConsumesThePendingResume() {
        var state = SpeechInterruptionState()
        _ = state.begin(wasPlaying: true)
        let resumes = state.end(allowsResume: false)
        let resumesAfterDuplicate = state.end(allowsResume: true)
        #expect(!resumes)
        #expect(!resumesAfterDuplicate)
    }

    /// 没有中断开始的结束事件不会产生播放动作。
    @Test func endingWithoutBeginningDoesNotStartPlayback() {
        var state = SpeechInterruptionState()
        let resumes = state.end(allowsResume: true)
        #expect(!resumes)
    }

    /// 前一次停止不会影响下一次正常播放遇到导航时的暂停和续播。
    @Test func aNewInterruptionHasItsOwnPlaybackIntent() {
        var state = SpeechInterruptionState()
        _ = state.begin(wasPlaying: true)
        state.cancelResume()
        let resumesCancelled = state.end(allowsResume: true)
        let pauses = state.begin(wasPlaying: true)
        let resumes = state.end(allowsResume: true)
        #expect(!resumesCancelled)
        #expect(pauses)
        #expect(resumes)
    }
}
