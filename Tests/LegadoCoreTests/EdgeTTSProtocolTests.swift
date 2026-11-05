import Foundation
import Testing
@testable import LegadoCore

/// 验证真实词边界到正文的映射，覆盖一份缓存跨页、重复文字及跨请求时间累计。
struct EdgeTTSProtocolTests {
    /// 长中文、emoji 和 XML 字符必须完整保留，并且每个请求都不超过字节上限。
    @Test func chunksPreserveSourceRangesAndXML() {
        let text = String(repeating: "中文📖 & <tag>\n", count: 800)
        let source = text as NSString
        let chunks = EdgeTTSText.chunks(text)
        #expect(chunks.count > 1)
        var position = 0
        for chunk in chunks {
            #expect(chunk.escapedText.utf8.count <= 4096)
            #expect(chunk.range.location == position)
            #expect(EdgeTTSText.unescape(chunk.escapedText) == source.substring(with: chunk.range))
            position = NSMaxRange(chunk.range)
        }
        #expect(position == source.length)
    }

    /// 多字节字符不能像旧实现一样绕过 4096 字节限制，原文中的实体也不能被删除。
    @Test func longUnspacedTextKeepsEveryCharacter() {
        let text = String(repeating: "你", count: 1400) + "😀&amp;"
        let chunks = EdgeTTSText.chunks(text)
        #expect(chunks.count == 2)
        #expect(chunks[0].escapedText.utf8.count == 4095)
        #expect(chunks.map { EdgeTTSText.unescape($0.escapedText) }.joined() == text)
    }

    /// 同一个 metadata 帧中的全部词边界都要保留，SessionEnd 不产生虚假文字。
    @Test func decodesAllWordBoundaries() throws {
        let message = "Path:audio.metadata\r\n\r\n" + """
        {"Metadata":[{"Type":"WordBoundary","Data":{"Offset":1000000,"text":{"Text":"你好"}}},{"Type":"SessionEnd"},{"Type":"WordBoundary","Data":{"Offset":7000000,"text":{"Text":"&amp;"}}}]}
        """
        guard case .metadata(let words) = try EdgeTTSMessage.textEvent(message) else {
            Issue.record("文字帧必须返回边界事件")
            return
        }
        #expect(words.count == 2)
        #expect(words[0].offset == 1_000_000)
        #expect(words.map(\.text) == ["你好", "&"])
    }

    /// 顺序匹配重复词及 emoji 后的 UTF-16 位置，XML 解码只做一遍。
    @Test func mapsWordsToOriginalUTF16Positions() throws {
        let text = "你好，📖 & 你好 &amp;"
        var timeline = EdgeTTSTimeline(text: text)
        let words = try [word("你好", offset: 1_000_000), word("📖", offset: 5_000_000),
                         word("&amp;", offset: 9_000_000), word("你好", offset: 12_000_000),
                         word("&amp;amp;", offset: 15_000_000)]
        try timeline.append(words, range: NSRange(location: 0, length: text.utf16.count), precedingAudioBytes: 0)
        #expect(timeline.boundaries.map(\.range.location) == [0, 3, 6, 8, 11])
        #expect(timeline.boundaries.last?.range.length == 5)
    }

    /// 跨块时间按实际 MP3 字节累计，不能按上一块最后一个词或文字比例估算。
    @Test func joinsChunkTimelineUsingCBRBytes() throws {
        var timeline = EdgeTTSTimeline(text: "第一块。第二块。")
        try timeline.append([word("第一块", offset: 1_000_000)], range: NSRange(location: 0, length: 4), precedingAudioBytes: 0)
        try timeline.append([word("第二块", offset: 1_000_000)], range: NSRange(location: 4, length: 4), precedingAudioBytes: 12_000)
        #expect(timeline.boundaries.map(\.offsetTicks) == [1_000_000, 21_000_000])
        #expect(timeline.boundaries.map(\.range.location) == [0, 4])
    }

    /// 页边界前后只由真实音频时间决定，同一缓存无需播放完即可定位到下一页。
    @Test func playbackTimeSelectsCurrentWord() {
        let boundaries: [HttpTTSSpeechBoundary] = [
            .init(offsetTicks: 1_000_000, range: NSRange(location: 0, length: 2)),
            .init(offsetTicks: 90_000_000, range: NSRange(location: 450, length: 2)),
            .init(offsetTicks: 170_000_000, range: NSRange(location: 900, length: 2))
        ]
        #expect(HttpTTSSpeechBoundary.position(at: 0, in: boundaries) == nil)
        #expect(HttpTTSSpeechBoundary.position(at: 8.99, in: boundaries) == 0)
        #expect(HttpTTSSpeechBoundary.position(at: 9, in: boundaries) == 450)
        #expect(HttpTTSSpeechBoundary.position(at: 16.99, in: boundaries) == 450)
        #expect(HttpTTSSpeechBoundary.position(at: 17, in: boundaries) == 900)
        #expect(HttpTTSSpeechBoundary.position(at: 100, in: boundaries) == 900)
    }

    /// 时间轴序列化后仍保留 UTF-16 位置，读取旧正文的缓存也能准确翻页。
    @Test func persistsTimelineWithoutLosingPositions() throws {
        let values = [HttpTTSSpeechBoundary(offsetTicks: 90_000_000, range: NSRange(location: 450, length: 2))]
        let data = try PropertyListEncoder().encode(values)
        let decoded = try PropertyListDecoder().decode([HttpTTSSpeechBoundary].self, from: data)
        #expect(decoded == values)
    }

    /// 文字与原文对不上时必须报告错误，不猜测位置或静默跳过不认识的词。
    @Test func reportsMismatchedWord() throws {
        var timeline = EdgeTTSTimeline(text: "原文")
        let words = try [word("其他文字", offset: 0)]
        #expect(throws: EdgeTTSError.self) {
            try timeline.append(words, range: NSRange(location: 0, length: 2), precedingAudioBytes: 0)
        }
    }

    /// 二进制帧使用实际服务端的头部长度定义，MP3 的首字节不得丢失。
    @Test func decodesBinaryFrameWithTrailingCRLF() throws {
        let header = Data("X-RequestId:test\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n".utf8)
        var frame = Data([UInt8(header.count >> 8), UInt8(header.count & 255)])
        frame.append(header)
        frame.append(contentsOf: [0xFF, 0xF3, 0x64, 0xC4])
        #expect(try EdgeTTSMessage.audioPayload(frame) == Data([0xFF, 0xF3, 0x64, 0xC4]))
    }

    /// 通过协议字段构造边界夹具，使用与真实服务相同的解码路径。
    private func word(_ text: String, offset: Int64) throws -> EdgeTTSWordBoundary {
        let data = try JSONSerialization.data(withJSONObject: ["Offset": offset, "text": ["Text": text]])
        return try JSONDecoder().decode(EdgeTTSWordBoundary.self, from: data)
    }
}
