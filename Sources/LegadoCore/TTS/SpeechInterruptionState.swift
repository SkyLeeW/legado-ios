/// 记录系统中断之前的播放意图，重复中断不会覆盖恢复状态，用户操作可以取消续播。
public struct SpeechInterruptionState: Sendable {
    private var isInterrupted = false
    private var resumesWhenAllowed = false

    /// 新的听书控制器从没有系统中断和待恢复播放的状态开始。
    public init() {}

    /// 首次中断记录是否正在播放，后续重复通知保留同一次中断的恢复意图。
    public mutating func begin(wasPlaying: Bool) -> Bool {
        if !isInterrupted { resumesWhenAllowed = wasPlaying }
        isInterrupted = true
        return wasPlaying
    }

    /// 只有系统允许且用户没有取消时恢复，处理完结束事件即消费本次恢复意图。
    public mutating func end(allowsResume: Bool) -> Bool {
        let resumes = isInterrupted && resumesWhenAllowed && allowsResume
        isInterrupted = false
        resumesWhenAllowed = false
        return resumes
    }

    /// 用户暂停、停止、切换内容或断开输出设备后，不再由旧的中断事件自动续播。
    public mutating func cancelResume() { resumesWhenAllowed = false }
}
