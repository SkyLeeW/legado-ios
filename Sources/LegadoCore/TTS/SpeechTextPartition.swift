import Foundation

/// 把实际可见页范围转换为互不重叠的朗读范围，音频切页时不会漏读或重复正文。
public enum SpeechTextPartition {
    /// 将页间分界顺延到系统识别的完整句末，跨页句子只合成一次，并完整保留起播后的原文。
    public static func sentenceAlignedPages(text: String, position: Int, visibleRanges: [NSRange]) -> [NSRange] {
        let pageRanges = pages(text: text, position: position, visibleRanges: visibleRanges)
        return alignedToSentences(text: text, position: position, preferredBoundaries: pageRanges.dropFirst().map(\.location))
    }

    /// 所有渠道共用句末分界算法，字数、半章和页尾只决定目标长度，不直接截断正在朗读的句子。
    public static func alignedToSentences(text: String, position: Int, preferredBoundaries: [Int]) -> [NSRange] {
        let source = text as NSString
        if source.length == 0 || position >= source.length { return [] }
        let beginning = source.rangeOfComposedCharacterSequence(at: position).location
        let boundaries = Array(Set(preferredBoundaries.filter { $0 > beginning && $0 < source.length })).sorted()
        var boundaryIndex = 0
        var start = beginning
        var result: [NSRange] = []
        for sentence in sentenceRanges(text: text) {
            let end = NSMaxRange(sentence)
            if boundaryIndex < boundaries.count, boundaries[boundaryIndex] <= end {
                while boundaryIndex < boundaries.count, boundaries[boundaryIndex] <= end { boundaryIndex += 1 }
                result.append(NSRange(location: start, length: end - start))
                start = end
            }
        }
        if start < source.length { result.append(NSRange(location: start, length: source.length - start)) }
        return result
    }

    /// 系统句子枚举的 enclosingRange 完整覆盖原文及分隔符，各渠道复用同一组自然语言边界。
    static func sentenceRanges(text: String) -> [NSRange] {
        let source = text as NSString
        var result: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: [.bySentences, .substringNotRequired]) { _, _, enclosingRange, _ in
            result.append(enclosingRange)
        }
        return result
    }

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
