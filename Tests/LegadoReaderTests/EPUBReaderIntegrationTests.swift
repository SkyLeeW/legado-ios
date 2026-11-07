import XCTest
import UIKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
import ZIPFoundation
@testable import Legado

@MainActor
final class EPUBReaderIntegrationTests: XCTestCase {
    /// 连续开关菜单时正文视口和首个可见文本必须保持不变，防止重新分页造成跳页。
    func testTogglingControlsKeepsViewportAndVisibleText() async throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("无法清理 EPUB 回归目录：\(error)") }
        }
        let url = root.appendingPathComponent("long.epub")
        try makeEPUB(at: url, paragraphCount: 80)
        let report = try LocalBookService().openFile(at: url)
        let chapter = try XCTUnwrap(report.chapters.first { $0.resourceUrl == "Text/chapter.xhtml" })
        let model = EPUBReaderModel(book: report.book, chapters: report.chapters, initialIndex: chapter.index)
        await model.open(preferences: .init(publisherStyles: true))
        XCTAssertNil(model.errorMessage)
        let navigator = try XCTUnwrap(model.navigator)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let library = BookLibraryModel(
            repository: InMemoryBookRepository(books: [report.book]),
            localDirectory: root,
            chapterRepository: InMemoryBookChapterRepository(),
            progressDefaults: defaults
        )
        let reader = EPUBReaderView(model: model)
            .environmentObject(library)
            .environmentObject(ReadingActivityModel.demo())
            .environmentObject(ReplaceRuleLibraryModel.demo())
        let host = UIHostingController(rootView: reader)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        try await waitForJavaScript("!!document.querySelector('#paragraph79')", in: navigator)
        try await waitForPagination("Text/chapter.xhtml", in: navigator)
        await model.go(to: ReadiumShared.Link(href: "Text/chapter.xhtml#paragraph20", mediaType: .xhtml))
        XCTAssertNil(model.errorMessage)
        try await waitForLocation("Text/chapter.xhtml", in: model)
        try await waitForJavaScript("""
        Array.from(document.querySelector('#paragraph20').getClientRects()).some(rect =>
            rect.right > 0 && rect.left < window.innerWidth &&
            rect.bottom > 0 && rect.top < window.innerHeight)
        """, in: navigator)
        let originalBounds = navigator.view.bounds
        let visibleElement = await navigator.firstVisibleElementLocator()
        let originalVisible = try XCTUnwrap(visibleElement)

        for visible in [false, true, false, true] {
            model.showsControls = visible
            // 通过 UIHostingController 的根视图更新执行实际 SwiftUI 布局，不重建导航控制器。
            host.rootView = reader
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            XCTAssertEqual(navigator.view.bounds, originalBounds, "菜单开关不应改变 EPUB 正文视口")
            let currentElement = await navigator.firstVisibleElementLocator()
            let currentVisible = try XCTUnwrap(currentElement)
            XCTAssertEqual(currentVisible.href, originalVisible.href)
            XCTAssertEqual(currentVisible.text, originalVisible.text, "菜单开关不应改变当前可见文本")
        }

        // 进入听书时保留实际可见字符，返回时恢复到同章的目标段落而不是章节起点。
        let synchronized = try await model.readingBook(report.book, rules: [])
        XCTAssertEqual(synchronized.durChapterIndex, chapter.index)
        XCTAssertGreaterThan(synchronized.durChapterPos, 0)
        let raw = try XCTUnwrap(try LocalBookService().loadContent(book: report.book, chapter: chapter).epubTextMap)
        let processed = ContentSanitizer().process(book: report.book, chapter: chapter, content: raw.text,
                                                 rules: [], tracksSourceOffsets: true)
        let position = (processed.content as NSString).range(of: "第55段：").location
        XCTAssertNotEqual(position, NSNotFound)
        var listened = synchronized
        listened.durChapterPos = position
        listened.readConfig?.epubLocation = try raw.processed(processed).locatorJSON(chapter: chapter, position: position)
        await model.resumeAfterTextReading(listened)
        XCTAssertNil(model.errorMessage)
        try await waitForJavaScript("""
        Array.from(document.querySelector('#paragraph55').getClientRects()).some(rect =>
            rect.right > 0 && rect.left < window.innerWidth &&
            rect.bottom > 0 && rect.top < window.innerHeight)
        """, in: navigator)
    }

    func testOriginalCoverStylesImagesTablesAndRestoredLocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("layout.epub")
        try makeEPUB(at: url)
        let report = try LocalBookService().openFile(at: url)
        XCTAssertNotNil(report.book.coverUrl)
        let model = EPUBReaderModel(book: report.book, chapters: report.chapters, initialIndex: 0)
        await model.open(preferences: .init(publisherStyles: true))
        XCTAssertNil(model.errorMessage)
        let navigator = try XCTUnwrap(model.navigator)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigator
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        try await waitForJavaScript("!!document.querySelector('svg image')", in: navigator)
        XCTAssertEqual(model.tableOfContents.map { $0.link.title }, ["封面", "图文正文"])
        await model.go(to: ReadiumShared.Link(href: "Text/chapter.xhtml#body", mediaType: .xhtml))
        try await waitForJavaScript("document.querySelector('#illustration')?.complete && document.querySelector('#illustration').naturalWidth > 0 && getComputedStyle(document.querySelector('table')).borderTopStyle === 'solid' && document.querySelectorAll('td').length === 2", in: navigator)
        try await waitForLocation("Text/chapter.xhtml", in: model)
        let locator = try XCTUnwrap(model.location)
        XCTAssertEqual(EPUBReaderModel.path(locator.href.string), "Text/chapter.xhtml")
        var saved = report.book
        saved.readConfig?.epubLocation = try locator.jsonString()
        saved.durChapterIndex = try XCTUnwrap(model.currentChapter).index
        let restored = EPUBReaderModel(book: saved, chapters: report.chapters, initialIndex: saved.durChapterIndex)
        await restored.open(preferences: .init(fontSize: 1.4, publisherStyles: true))
        let reopened = try XCTUnwrap(restored.navigator)
        window.rootViewController = reopened
        window.layoutIfNeeded()
        try await waitForJavaScript("!!document.querySelector('#body') && !!document.querySelector('table')", in: reopened)
        try await waitForLocation("Text/chapter.xhtml", in: restored)
        XCTAssertEqual(EPUBReaderModel.path(try XCTUnwrap(restored.location).href.string), "Text/chapter.xhtml")
    }

    /// 以 Readium 的分页视口报告为就绪条件，避免在 CSS 排版之前读取整章文本作为基准。
    private func waitForPagination(_ path: String, in navigator: EPUBNavigatorViewController) async throws {
        for _ in 0..<150 {
            if let range = navigator.viewport?.progressions.first(where: {
                EPUBReaderModel.path($0.key.string) == path
            })?.value {
                let visibleFraction = range.upperBound - range.lowerBound
                if visibleFraction > 0, visibleFraction < 1 { return }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Readium 尚未将长正文分页，不能建立阅读位置基准")
    }

    private func waitForLocation(_ path: String, in model: EPUBReaderModel) async throws {
        // Readium reports locations after the spread has finished laying out.
        for _ in 0..<100 {
            if let location = model.location, EPUBReaderModel.path(location.href.string) == path { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("EPUB location did not settle on \(path)")
    }

    private func waitForJavaScript(_ expression: String, in navigator: EPUBNavigatorViewController) async throws {
        for _ in 0..<150 {
            if let value = try? await navigator.evaluateJavaScript(expression).get() as? Bool, value { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("EPUB content did not render: \(expression)")
    }

    /// 生成包含原书样式和可选长正文的独立 EPUB，供渲染与分页回归使用。
    private func makeEPUB(at url: URL, paragraphCount: Int = 0) throws {
        let paragraphs = (0..<paragraphCount).map { index in
            "<p id=\"paragraph\(index)\">第\(index)段：雨停以后，我们沿着河岸走向灯塔。书页应当保留当前位置，菜单的显示与隐藏不应改变正在阅读的文字。</p>"
        }.joined()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABgCAIAAAAip+O/AAABxklEQVR4nNXCA3YjAABF0becsW12bNdIGptt7Nq2bXeMjc06/j2XI8UG6RwtMUrnWGmtdI6XmaRzotwsnZMVFumcqrRK53SVTTpnqu3SOVvjkM45g1M6540u6VyodUvnoskjnUtmr3QuW3zSuWL1S+eqLSCda/agdK47QtK54QxL56arTjq33PXSue2JSOeONyqdu76YdO7549K5H0hI50EwKZ2HoZR0isJp6Tyqy0jncX1WOk8iOek8jeal8yxWkM7zeIN0XiQapfMy2SSdV6lm6bxOt0jnTaZVOm+zbdJ5l2uXzvt8h3Q+FDql87GhSzqfGrul87mpRzpfmnulU9zSJ52S1n7plLYNSKesfVA65R1D0qnoHJZOZdeIdKq6R6VT3TMmnZrecekY+iakY+yflE7twJR0TIPT0jEPzUjHMjwrHevInHRso/PSsY8tSMcxvigd58SSdFyTy9JxT61IxzO9Kh3vzJp0fLPr0vHPbUgnML8pneDClnRCi9vSCS/tSKdueVc69St70oms7ksnunYgndj6oXTiG1+lk9j8Jp3k1nfppLZ/SCe981M6md1f0snu/ZZObv+PdPIHf6VTOPwn/T/zbe3/96qaXAAAAABJRU5ErkJggg==")!
        let files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(##"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"##.utf8)),
            ("book.opf", Data("""
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">layout-test</dc:identifier><dc:title>图文回归</dc:title><dc:language>zh</dc:language><meta property="dcterms:modified">2026-10-28T00:00:00Z</meta></metadata>
            <manifest><item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="body" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="image" href="Images/cover.png" media-type="image/png" properties="cover-image"/>
            <item id="css" href="Styles/book.css" media-type="text/css"/></manifest>
            <spine><itemref idref="cover"/><itemref idref="body"/></spine></package>
            """.utf8)),
            ("cover.xhtml", Data(##"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>封面</title></head><body><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 140"><image xlink:href="Images/cover.png" width="100" height="140"/></svg></body></html>"##.utf8)),
            ("Text/chapter.xhtml", Data(##"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>图文正文</title><link rel="stylesheet" href="../Styles/book.css"/></head><body><h1 id="body">图文正文</h1><p>图片与表格保留在原位置。</p><img id="illustration" src="../Images/cover.png" alt="内嵌插图"/><table><tr><td>项目</td><td>数值</td></tr></table><p><a href="#note">脚注</a></p><aside id="note">脚注内容</aside>\##(paragraphs)</body></html>"##.utf8)),
            ("nav.xhtml", Data(##"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="cover.xhtml">封面</a></li><li><a href="Text/chapter.xhtml#body">图文正文</a></li></ol></nav></body></html>"##.utf8)),
            ("Styles/book.css", Data("table { border: 3px solid #123456; } img { max-width: 80%; }".utf8)),
            ("Images/cover.png", png)
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { offset, size in
                data.subdata(in: Int(offset)..<(Int(offset) + size))
            }
        }
    }
}
