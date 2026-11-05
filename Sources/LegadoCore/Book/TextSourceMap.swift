import Foundation

/// 一次正文替换的原始范围及替换结果，供净化与位置映射共享同一次匹配。
struct TextReplacement: Sendable {
    let range: NSRange
    let text: String
}

/// 为每个 UTF-16 单元保留来源位置，删除和替换正文时同步转换阅读坐标。
public struct TextSourceMap: Sendable {
    public var text: String
    public var sourceOffsets: [Int]
    public var sourceLength: Int

    /// 原文的每个字符最初对应自身位置，后续转换只改动被处理的范围。
    public init(_ text: String) {
        self.text = text
        sourceOffsets = Array(0..<text.utf16.count)
        sourceLength = text.utf16.count
    }

    /// 按已排序且不重叠的匹配执行替换，新文字归属于被替换的原文起点。
    mutating func replace(_ edits: [TextReplacement]) {
        let original = text as NSString
        var output = ""
        var offsets: [Int] = []
        var cursor = 0
        for edit in edits {
            output += original.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)) + edit.text
            offsets.append(contentsOf: sourceOffsets[cursor..<edit.range.location])
            let origin = edit.range.location < sourceOffsets.count ? sourceOffsets[edit.range.location] : sourceLength
            offsets.append(contentsOf: repeatElement(origin, count: edit.text.utf16.count))
            cursor = NSMaxRange(edit.range)
        }
        output += original.substring(from: cursor)
        offsets.append(contentsOf: sourceOffsets[cursor...])
        text = output
        sourceOffsets = offsets
    }

    /// 逐行删除首尾空白及空行，换行保留下一段之前的真实来源位置。
    mutating func trimLines() {
        let original = text as NSString
        var output = ""
        var offsets: [Int] = []
        var cursor = 0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let range = (line as NSString).range(of: trimmed)
                let start = cursor + range.location
                if !output.isEmpty {
                    output += "\n"
                    offsets.append(sourceOffsets[start])
                }
                output += original.substring(with: NSRange(location: start, length: range.length))
                offsets.append(contentsOf: sourceOffsets[start..<start + range.length])
            }
            cursor += line.utf16.count + 1
        }
        text = output
        sourceOffsets = offsets
    }

    /// 从来源位置找到处理后正文中第一个尚未读过的字符，重复段落也不会混淆。
    public func position(forSourceOffset offset: Int) -> Int {
        var lower = 0
        var upper = sourceOffsets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sourceOffsets[middle] < offset { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
