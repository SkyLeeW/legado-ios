import Foundation
import Testing
@testable import LegadoCore

struct SpeechTextPartitionTests {
    /// 相邻页面共享可见行时，合成范围仍完整且只覆盖原文一次。
    @Test func overlappingPagesDoNotRepeatOrOmitText() {
        let text = "甲乙丙丁戊己庚辛壬癸"
        let ranges = SpeechTextPartition.pages(text: text, position: 0, visibleRanges: [
            NSRange(location: 0, length: 5), NSRange(location: 4, length: 5), NSRange(location: 7, length: 3)
        ])
        #expect(ranges == [NSRange(location: 0, length: 4), NSRange(location: 4, length: 3), NSRange(location: 7, length: 3)])
        #expect(ranges.map { (text as NSString).substring(with: $0) }.joined() == text)
    }

    /// 页边界落在 emoji 内部时，完整字符归入同一页且保留起播之后的全部正文。
    @Test func composedCharactersAndPartialStartStayIntact() {
        let text = "甲👨‍👩‍👧乙丙"
        let ranges = SpeechTextPartition.pages(text: text, position: 2, visibleRanges: [
            NSRange(location: 0, length: 5), NSRange(location: 3, length: 5), NSRange(location: 9, length: 2)
        ])
        #expect(ranges.map { (text as NSString).substring(with: $0) }.joined() == "👨‍👩‍👧乙丙")
        #expect(SpeechTextPartition.pages(text: text, position: text.utf16.count, visibleRanges: []).isEmpty)
        #expect(SpeechTextPartition.pages(text: "", position: 0, visibleRanges: []).isEmpty)
    }
}
