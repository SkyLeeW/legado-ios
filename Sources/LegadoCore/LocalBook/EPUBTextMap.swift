import Foundation
import SwiftSoup

/// EPUB 的 DOM 文本节点位置，字符偏移与 WebKit、TextKit 一样使用 UTF-16。
public struct EPUBTextPoint: Codable, Sendable {
    public let cssSelector: String
    public let textNodeIndex: Int
    public let offset: Int
}

/// 同一份正文同时保留 DOM 来源与阅读坐标，使原排版和听书可以双向定位。
public struct EPUBTextMap: Sendable {
    /// 按 EPUB 声明的媒体类型解析正文，与 WebKit 保持相同的 XML 或 HTML 节点结构。
    static func document(_ markup: String, mediaType: String) throws -> Document {
        let xml = mediaType.hasSuffix("+xml") || mediaType == "application/xml" || mediaType == "text/xml"
        return try SwiftSoup.parse(markup, "", xml ? Parser.xmlParser() : Parser.htmlParser())
    }

    struct SourceNode: Sendable {
        let selector: String
        let childIndex: Int
        let range: NSRange
        let parentText: String
        let parentOffset: Int
    }

    public private(set) var sourceMap = TextSourceMap("")
    private var nodes: [SourceNode] = []
    private(set) var images: [(src: String, alt: String)] = []
    public var text: String { sourceMap.text }

    /// 遍历原始 DOM 并保留空白折叠、章节锚点和插图文字的来源，重复正文按节点区分。
    init(body: Element, from start: String?, to end: String?) throws {
        var offsets: [ObjectIdentifier: Int] = [:]
        var endOffsets: [ObjectIdentifier: Int] = [:]
        var cursor = 0

        /// 取得 DOM textContent 的原始内容，作为精确文本引用的上下文。
        func rawText(_ node: Node) -> String {
            var stack = [node]
            var text = ""
            while let current = stack.popLast() {
                if let current = current as? TextNode { text += current.getWholeText() }
                else if let current = current as? DataNode { text += current.getWholeData() }
                else { stack.append(contentsOf: current.getChildNodes().reversed()) }
            }
            return text
        }

        /// 为每个文本节点记录稳定的元素路径，图片单独占用一个来源位置。
        func collect(_ element: Element, selector: String, depth: Int) throws {
            guard depth < 512 else { throw EPUBError.invalidPackage }
            offsets[ObjectIdentifier(element)] = cursor
            let parentText = rawText(element)
            if ["img", "image"].contains(element.tagName().lowercased()) {
                nodes.append(.init(selector: selector, childIndex: -1, range: NSRange(location: cursor, length: 1), parentText: "", parentOffset: 0))
                cursor += 1
            }
            var local = 0
            var elementIndex = 0
            for (childIndex, child) in element.getChildNodes().enumerated() {
                if let text = child as? TextNode {
                    let length = text.getWholeText().utf16.count
                    offsets[ObjectIdentifier(text)] = cursor
                    if length > 0 {
                        nodes.append(.init(selector: selector, childIndex: childIndex,
                                           range: NSRange(location: cursor, length: length), parentText: parentText, parentOffset: local))
                    }
                    cursor += length
                    local += length
                } else if let data = child as? DataNode {
                    let length = data.getWholeData().utf16.count
                    cursor += length
                    local += length
                } else if let child = child as? Element {
                    elementIndex += 1
                    try collect(child, selector: selector + " > :nth-child(\(elementIndex))", depth: depth + 1)
                    local += rawText(child).utf16.count
                }
            }
            endOffsets[ObjectIdentifier(element)] = cursor
        }
        try collect(body, selector: "body", depth: 0)
        var active = start == nil
        var foundStart = start == nil
        var foundEnd = end == nil
        var finished = false
        var output = ""
        var origins: [Int] = []
        let whitespace = try NSRegularExpression(pattern: #"\s+"#)
        let blocks: Set<String> = ["p", "div", "section", "article", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "tr", "hr"]

        /// 添加排版分隔或图片占位文字，并保留它所属的 DOM 位置。
        func append(_ value: String, origin: Int) {
            output += value
            origins.append(contentsOf: repeatElement(origin, count: value.utf16.count))
        }

        /// 按章内锚点提取正文，文字空白折叠只改变显示坐标而不丢失来源。
        func visit(_ node: Node, depth: Int) throws {
            guard depth < 512 else { throw EPUBError.invalidPackage }
            if finished { return }
            guard let element = node as? Element else {
                if active, let text = node as? TextNode {
                    var mapped = TextSourceMap(text.getWholeText())
                    mapped.replace(whitespace.matches(in: mapped.text, range: NSRange(location: 0, length: mapped.text.utf16.count))
                        .map { .init(range: $0.range, text: " ") })
                    output += mapped.text
                    origins += mapped.sourceOffsets.map { $0 + offsets[ObjectIdentifier(text)]! }
                }
                return
            }
            let id = element.id()
            let name = try element.attr("name")
            if let end, id == end || name == end { active = false; finished = true; foundEnd = true; return }
            if let start, id == start || name == start { active = true; foundStart = true }
            let tag = element.tagName().lowercased()
            let style = try element.attr("style").lowercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            if ["script", "style", "noscript", "rt", "rp", "title"].contains(tag) || element.hasAttr("hidden") || style.contains("display:none") { return }
            let origin = offsets[ObjectIdentifier(element)]!
            if active, blocks.contains(tag) || tag == "br" { append("\n", origin: origin) }
            if active, tag == "img" || tag == "image" {
                var src = try element.attr(tag == "img" ? "src" : "xlink:href")
                if src.isEmpty, tag == "image" { src = try element.attr("href") }
                let alt = try element.attr("alt")
                if !src.isEmpty {
                    images.append((src, alt))
                    append("\n【插图 \(images.count)\(alt.isEmpty ? "" : "：" + alt)】\n", origin: origin)
                }
            }
            for child in element.getChildNodes() { try visit(child, depth: depth + 1) }
            if active, blocks.contains(tag) { append("\n", origin: endOffsets[ObjectIdentifier(element)]!) }
            if active, tag == "td" || tag == "th" { append(" ", origin: endOffsets[ObjectIdentifier(element)]!) }
        }
        try visit(body, depth: 0)
        guard foundStart && foundEnd else { throw EPUBError.invalidChapter }
        sourceMap = TextSourceMap(output)
        sourceMap.sourceOffsets = origins
        sourceMap.sourceLength = cursor
        sourceMap.trimLines()
    }

    /// 将净化后的文字坐标组合到 DOM 来源，替换规则不会使两个阅读页面产生不同进度。
    public func processed(_ report: ContentProcessingReport) -> Self {
        var result = self
        result.sourceMap.text = report.content
        // 空正文没有字符来源；章尾插入的文字归属于章尾字符，定位仍落在原书正文内。
        if sourceMap.sourceOffsets.isEmpty {
            result.sourceMap.sourceOffsets = []
            return result
        }
        result.sourceMap.sourceOffsets = report.sourceMap!.sourceOffsets.map {
            sourceMap.sourceOffsets[min($0, sourceMap.sourceOffsets.count - 1)]
        }
        return result
    }

    /// 把 WebKit 的实际可见文本节点转换成当前章节位置，章外节点不属于这份正文。
    public func position(of point: EPUBTextPoint) -> Int? {
        guard let node = nodes.first(where: { $0.selector == point.cssSelector && $0.childIndex == point.textNodeIndex }),
              let first = sourceMap.sourceOffsets.first, let last = sourceMap.sourceOffsets.last else { return nil }
        let offset = node.range.location + point.offset
        guard offset >= first, offset <= last else { return nil }
        return sourceMap.position(forSourceOffset: offset)
    }

    /// 生成带元素路径及完整前后文的 Readium Locator，精确区分同章内相同文字。
    public func locatorJSON(chapter: BookChapter, position: Int) throws -> String {
        var href = URLComponents()
        href.path = chapter.resourceUrl!
        href.fragment = chapter.startFragmentId
        var locations: [String: Any] = [:]
        var quote: [String: String] = [:]
        if !sourceMap.sourceOffsets.isEmpty {
            let source = sourceMap.sourceOffsets[min(position, sourceMap.sourceOffsets.count - 1)]
            let node = nodes.first { NSLocationInRange(source, $0.range) }!
            locations["cssSelector"] = node.selector
            if node.childIndex >= 0 {
                let parent = node.parentText as NSString
                let target = parent.rangeOfComposedCharacterSequence(at: node.parentOffset + source - node.range.location)
                quote = ["before": parent.substring(to: target.location), "highlight": parent.substring(with: target),
                         "after": parent.substring(from: NSMaxRange(target))]
            }
        } else if let fragment = chapter.startFragmentId {
            locations["fragments"] = [fragment]
        }
        let data = try JSONSerialization.data(withJSONObject: ["href": href.string!, "type": "application/xhtml+xml",
            "title": chapter.title, "locations": locations, "text": quote], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
