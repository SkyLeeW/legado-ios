import Foundation
import SwiftSoup

public struct MetadataTextSanitizer: Sendable {
    public init() {}

    public func clean(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        do {
            value = replacingBlockTagsWithNewlines(value)
            let document = try SwiftSoup.parseBodyFragment(value)
            try document.select("script,style,noscript").remove()
            value = try document.body()?.text(trimAndNormaliseWhitespace: false) ?? document.text()
        } catch {
            value = value.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            value = (try? Parser.unescapeEntities(value, false)) ?? value
        }

        value = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
        let output = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let result = output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func replacingBlockTagsWithNewlines(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)<\s*br\s*/?\s*>|<\s*/?\s*(?:p|div|li|ul|ol|section|article|blockquote|h[1-6])\b[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
    }
}

struct ChapterHTMLFormatter {
    func format(_ html: String, baseURL: URL) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)<img\b[^>]*>"#) else {
            return MetadataTextSanitizer().clean(html) ?? ""
        }
        var protected = html
        var images: [String: String] = [:]
        let token = UUID().uuidString
        for (index, match) in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).enumerated().reversed() {
            guard let range = Range(match.range, in: html),
                  let element = try? SwiftSoup.parseBodyFragment(String(html[range])).select("img").first() else { continue }
            let src = ["data-src", "data-original", "data-srcset", "src"]
                .compactMap { try? element.attr($0) }.first { !$0.isEmpty } ?? ""
            let marker = "LEGADO_IMAGE_\(token)_\(index)"
            let url = LegadoURLBuilder.resolve(src, against: baseURL)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            images[marker] = src.isEmpty ? "" : "<img src=\"\(url)\">"
            protected.replaceSubrange(range, with: "\n\(marker)\n")
        }
        var result = MetadataTextSanitizer().clean(protected) ?? ""
        for (marker, image) in images { result = result.replacingOccurrences(of: marker, with: image) }
        return result
    }
}

public struct ContentProcessingReport: Sendable {
    public var title: String
    public var content: String
    public var effectiveRuleIDs: [Int64]
    public var removedDuplicateTitle: Bool
    public var diagnostics: [RuleDiagnostic]
    public var sourceMap: TextSourceMap? = nil

    public init(
        title: String,
        content: String,
        effectiveRuleIDs: [Int64] = [],
        removedDuplicateTitle: Bool = false,
        diagnostics: [RuleDiagnostic] = []
    ) {
        self.title = title
        self.content = content
        self.effectiveRuleIDs = effectiveRuleIDs
        self.removedDuplicateTitle = removedDuplicateTitle
        self.diagnostics = diagnostics
    }
}

public struct ContentSanitizer: Sendable {
    private let regex: RegexEvaluator

    public init(regex: RegexEvaluator = .init()) {
        self.regex = regex
    }

    /// 按既有顺序净化标题和正文，可同步记录每个输出字符在原文中的来源位置。
    public func process(
        book: Book,
        chapter: BookChapter,
        content: String,
        rules: [ReplaceRule],
        removeDuplicateTitle: Bool = true,
        resegment: Bool = true,
        tracksSourceOffsets: Bool = false
    ) -> ContentProcessingReport {
        let ordered = rules.filter(\.isEnabled).sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
        var title = chapter.title
        var body = content
        var bodyMap = tracksSourceOffsets ? TextSourceMap(content) : nil
        var effective: [Int64] = []
        var diagnostics: [RuleDiagnostic] = []

        for rule in ordered where rule.scopeTitle && applies(rule, to: book) {
            let result = apply(rule, to: title, book: book, chapter: chapter)
            diagnostics += result.diagnostics
            if result.value != title, !result.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = result.value
                effective.append(rule.id)
            }
        }

        var removed = false
        if removeDuplicateTitle {
            let lines = body.components(separatedBy: .newlines)
            if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                let normalizedLine = normalize(lines[firstIndex])
                let normalizedTitles = [chapter.title, title, book.name + chapter.title].map(normalize)
                if normalizedTitles.contains(normalizedLine) {
                    var updated = lines
                    updated.remove(at: firstIndex)
                    body = updated.joined(separator: "\n")
                    var start = lines[..<firstIndex].reduce(0) { $0 + $1.utf16.count + 1 }
                    var length = lines[firstIndex].utf16.count
                    if firstIndex < lines.count - 1 { length += 1 }
                    else if firstIndex > 0 { start -= 1; length += 1 }
                    bodyMap?.replace([.init(range: NSRange(location: start, length: length), text: "")])
                    removed = true
                }
            }
        }

        if resegment {
            body = body.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "　"))) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            bodyMap?.trimLines()
        }

        for rule in ordered where rule.scopeContent && applies(rule, to: book) {
            let result = apply(rule, to: body, book: book, chapter: chapter)
            diagnostics += result.diagnostics
            if result.value != body {
                body = result.value
                bodyMap?.replace(result.edits)
                effective.append(rule.id)
            }
        }

        var seen = Set<Int64>()
        effective = effective.filter { seen.insert($0).inserted }
        var report = ContentProcessingReport(
            title: title,
            content: body,
            effectiveRuleIDs: effective,
            removedDuplicateTitle: removed,
            diagnostics: diagnostics
        )
        report.sourceMap = bodyMap
        return report
    }

    private func applies(_ rule: ReplaceRule, to book: Book) -> Bool {
        if let excluded = rule.excludeScope, !excluded.isEmpty,
           (!book.name.isEmpty && excluded.contains(book.name)) || (!book.origin.isEmpty && excluded.contains(book.origin)) { return false }
        guard let scope = rule.scope, !scope.isEmpty else { return true }
        return (!book.name.isEmpty && scope.contains(book.name)) || (!book.origin.isEmpty && scope.contains(book.origin))
    }

    /// 净化规则同时返回真实替换范围，EPUB 同步位置无需重新匹配或重复执行脚本。
    private func apply(_ rule: ReplaceRule, to input: String, book: Book, chapter: BookChapter) -> (value: String, diagnostics: [RuleDiagnostic], edits: [TextReplacement]) {
        guard !rule.pattern.isEmpty else { return (input, [], []) }
        var edits: [TextReplacement] = []
        let record: (NSRange, String) -> Void = { edits.append(.init(range: $0, text: $1)) }
        do {
            if rule.isRegex {
                if rule.replacement.hasPrefix("@js:") {
                    let evaluate = JavaScriptRuleEvaluator().replacementEvaluator(
                        script: String(rule.replacement.dropFirst(4)), book: book, chapter: chapter)
                    let value = try regex.replacingStrict(pattern: rule.pattern, in: input,
                        timeoutMilliseconds: rule.timeoutMillisecond, onReplacement: record, replacement: evaluate)
                    return (value, [], edits)
                }
                let value = try regex.replacingStrict(pattern: rule.pattern, in: input, timeoutMilliseconds: rule.timeoutMillisecond,
                                                     onReplacement: record) { expression, match in
                    expression.replacementString(for: match, in: input, offset: 0, template: rule.replacement)
                }
                return (value, [], edits)
            }
            let original = input as NSString
            var cursor = 0
            while cursor < original.length {
                let range = original.range(of: rule.pattern, range: NSRange(location: cursor, length: original.length - cursor))
                if range.location == NSNotFound { break }
                record(range, rule.replacement)
                cursor = NSMaxRange(range)
            }
            return (input.replacingOccurrences(of: rule.pattern, with: rule.replacement), [], edits)
        } catch let error as RuleEngineError {
            return (input, [error.diagnostic], [])
        } catch {
            return (input, [.init(
                severity: .error,
                code: "replace.failed",
                message: "净化规则“\(rule.name)”执行失败：\(error.localizedDescription)",
                rule: rule.pattern
            )], [])
        }
    }

    private func normalize(_ value: String) -> String {
        value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }.map(String.init).joined().lowercased()
    }
}
