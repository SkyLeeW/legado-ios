import Foundation
import SwiftSoup
import Testing
@testable import LegadoCore

struct EPUBTextMapTests {
    /// 重复段落通过 DOM 节点区分，emoji 的双 UTF-16 单元不会改变章内位置。
    @Test func repeatedParagraphsAndEmojiKeepTheirDOMIdentity() throws {
        let body = try SwiftSoup.parse("<body><h1>章节</h1><p>相同👨‍👩‍👧文字</p><p>相同👨‍👩‍👧文字</p></body>").body()!
        let raw = try EPUBTextMap(body: body, from: nil, to: nil)
        let chapter = BookChapter(url: "one", title: "章节", bookUrl: "book", index: 0)
        let report = ContentSanitizer().process(book: Book(bookUrl: "book", name: "书"), chapter: chapter,
                                               content: raw.text, rules: [], tracksSourceOffsets: true)
        let map = raw.processed(report)
        #expect(report.removedDuplicateTitle)
        #expect(map.text == "相同👨‍👩‍👧文字\n相同👨‍👩‍👧文字")
        let position = "相同👨‍👩‍👧文字\n".utf16.count
        let json = try JSONSerialization.jsonObject(with: Data(map.locatorJSON(chapter: resourceChapter(), position: position).utf8)) as! [String: Any]
        #expect((json["locations"] as! [String: String])["cssSelector"] == "body > :nth-child(3)")
        let point = try JSONDecoder().decode(EPUBTextPoint.self, from: Data(#"{"cssSelector":"body > :nth-child(3)","textNodeIndex":0,"offset":2}"#.utf8))
        #expect(map.position(of: point) == position + 2)
        #expect(map.sourceMap.sourceOffsets == map.sourceMap.sourceOffsets.sorted())
    }

    /// 空白折叠、内联标签和净化替换均保留原文出处，避免返回原排版后偏移。
    @Test func whitespaceAndReplacementTrackOriginalCharacters() throws {
        let body = try SwiftSoup.parse("<body><p> 甲   <em>乙😀</em> 丙 </p><p>丁</p></body>").body()!
        let raw = try EPUBTextMap(body: body, from: nil, to: nil)
        #expect(raw.text == "甲 乙😀 丙\n丁")
        let rule = ReplaceRule(id: 1, name: "替换", pattern: "乙😀", replacement: "新的内容")
        let report = ContentSanitizer().process(book: Book(bookUrl: "book", name: "书"), chapter: resourceChapter(),
                                               content: raw.text, rules: [rule], tracksSourceOffsets: true)
        let map = raw.processed(report)
        #expect(map.text == "甲 新的内容 丙\n丁")
        #expect(map.sourceMap.sourceOffsets.count == map.text.utf16.count)
        let json = try JSONSerialization.jsonObject(with: Data(map.locatorJSON(chapter: resourceChapter(), position: 3).utf8)) as! [String: Any]
        #expect((json["locations"] as! [String: String])["cssSelector"] == "body > :nth-child(1) > :nth-child(1)")
        #expect((json["text"] as! [String: String])["highlight"] == "乙")
        #expect(map.sourceMap.sourceOffsets == map.sourceMap.sourceOffsets.sorted())
    }

    /// 同一资源的两个章节按锚点分开，图片占位和被隐藏的文字不破坏正文位置。
    @Test func chapterAnchorsAndImagesHaveSeparatePositions() throws {
        let body = try SwiftSoup.parse("<body><section id='a'><p>甲</p><img src='a.png'/><p hidden>隐藏</p></section><section id='b'><p>乙</p></section></body>").body()!
        let first = try EPUBTextMap(body: body, from: "a", to: "b")
        let second = try EPUBTextMap(body: body, from: "b", to: nil)
        #expect(first.text == "甲\n【插图 1】")
        #expect(second.text == "乙")
        let point = try JSONDecoder().decode(EPUBTextPoint.self, from: Data(#"{"cssSelector":"body > :nth-child(2) > :nth-child(1)","textNodeIndex":0,"offset":0}"#.utf8))
        #expect(first.position(of: point) == nil)
        #expect(second.position(of: point) == 0)
        let json = try JSONSerialization.jsonObject(with: Data(first.locatorJSON(chapter: resourceChapter(), position: 3).utf8)) as! [String: Any]
        #expect((json["locations"] as! [String: String])["cssSelector"] == "body > :nth-child(1) > :nth-child(2)")
    }

    /// 创建带原书资源路径的章节，让测试使用与 Readium 相同的 Locator 输入。
    private func resourceChapter() -> BookChapter {
        var chapter = BookChapter(url: "one", title: "章节", bookUrl: "book", index: 0)
        chapter.resourceUrl = "Text/one.xhtml"
        return chapter
    }

    /// 规则在章尾插入文字时仍定位到原书末尾，不能生成超出 DOM 的字符偏移。
    @Test func insertedTextAtChapterEndKeepsAValidLocator() throws {
        let body = try SwiftSoup.parse("<body><p>原文😀</p></body>").body()!
        let raw = try EPUBTextMap(body: body, from: nil, to: nil)
        let rule = ReplaceRule(id: 1, name: "添加", pattern: "$", replacement: "新增文字")
        let report = ContentSanitizer().process(book: Book(bookUrl: "book", name: "书"), chapter: resourceChapter(),
                                               content: raw.text, rules: [rule], tracksSourceOffsets: true)
        let map = raw.processed(report)
        let json = try JSONSerialization.jsonObject(with: Data(map.locatorJSON(chapter: resourceChapter(), position: map.text.utf16.count - 1).utf8)) as! [String: Any]
        #expect((json["text"] as! [String: String])["highlight"] == "😀")
    }

    /// XHTML 的表格不插入 HTML 专属的 tbody，元素路径与原书的 XML DOM 一致。
    @Test func xhtmlTablePathsMatchTheOriginalDOM() throws {
        let body = try SwiftSoup.parse(#"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><table><tr><td>项目</td><td>数值</td></tr></table></body></html>"#).body()!
        let raw = try EPUBTextMap(body: body, from: nil, to: nil)
        let json = try JSONSerialization.jsonObject(with: Data(raw.locatorJSON(chapter: resourceChapter(), position: 3).utf8)) as! [String: Any]
        #expect((json["locations"] as! [String: String])["cssSelector"] == "body > :nth-child(1) > :nth-child(1) > :nth-child(2)")
    }
}
