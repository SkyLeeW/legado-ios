import Foundation

/// 把实际可见页范围转换为互不重叠的朗读范围，音频切页时不会漏读或重复正文。
public enum SpeechTextPartition {
    /// 页边界和起播位置均落在完整字符上，最后一个范围始终覆盖到章尾。
    public static func pages(text: String, position: Int, visibleRanges: [NSRange]) -> [NSRange] {
        let source = text as NSString
        if source.length == 0 { return [] }
        let starts = Array(Set([0] + visibleRanges.map { source.rangeOfComposedCharacterSequence(at: $0.location).location })).sorted()
        let beginning = position < source.length ? source.rangeOfComposedCharacterSequence(at: position).location : source.length
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : source.length
            let spokenStart = max(start, beginning)
            return spokenStart < end ? NSRange(location: spokenStart, length: end - spokenStart) : nil
        }
    }
}
