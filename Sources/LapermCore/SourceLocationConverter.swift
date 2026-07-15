import Foundation
import Markdown

/// swift-markdown の SourceLocation(1-based 行、UTF-8 バイト単位 1-based 桁)を
/// UTF-16 ベースの NSRange に変換する。1 文書につき 1 インスタンス生成して使う。
struct SourceLocationConverter {
    private let text: String
    /// 各行の先頭を指す String.Index(UTF-8 視点で "\n" の直後)
    private let lineStartIndices: [String.Index]

    init(text: String) {
        self.text = text
        var starts: [String.Index] = [text.startIndex]
        let utf8 = text.utf8
        var i = utf8.startIndex
        while i < utf8.endIndex {
            if utf8[i] == UInt8(ascii: "\n") {
                starts.append(utf8.index(after: i))
            }
            i = utf8.index(after: i)
        }
        self.lineStartIndices = starts
    }

    func nsRange(of sourceRange: SourceRange) -> NSRange? {
        guard let lower = stringIndex(of: sourceRange.lowerBound),
              let upper = stringIndex(of: sourceRange.upperBound),
              lower <= upper else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    private func stringIndex(of location: SourceLocation) -> String.Index? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndices.count else { return nil }
        let lineStart = lineStartIndices[lineIndex]
        let utf8 = text.utf8
        guard let index = utf8.index(
            lineStart,
            offsetBy: location.column - 1,
            limitedBy: utf8.endIndex
        ) else { return nil }
        // 行内桁が実際には次行へはみ出すケース(不正な column)を拒否する
        if lineIndex + 1 < lineStartIndices.count, index > lineStartIndices[lineIndex + 1] {
            return nil
        }
        return index
    }
}
