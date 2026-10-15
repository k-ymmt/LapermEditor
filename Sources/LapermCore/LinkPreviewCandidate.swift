import Foundation

/// 中身が裸の `http(s)://` の URL 1 つだけ(前後は空白のみ)の段落(Laperm ADR 0046)。UI 層が Live Preview でその
/// ページのカード(Link Preview)に折りたたむために使う。レンジはすべて原文の UTF-16 オフセット。
///
/// 文中の URL、`[]()`、`<URL>`、リスト項目・引用・表の中の段落、Front Matter は候補にならない。
public struct LinkPreviewCandidate: Hashable, Sendable {
    /// 段落の行全体(行頭から行末まで。改行を含まない。URL の前後の空白を含む)。ブロックの段落はここから始まる。
    public var range: NSRange
    /// URL そのもの(`range` の中)。
    public var urlRange: NSRange
    /// 書かれたままの URL 文字列(開くときに渡す)。
    public var destination: String

    public init(range: NSRange, urlRange: NSRange, destination: String) {
        self.range = range
        self.urlRange = urlRange
        self.destination = destination
    }

    /// すべてのレンジを `delta` だけ平行移動したもの。
    public func shifted(by delta: Int) -> LinkPreviewCandidate {
        var moved = self
        moved.range = NSRange(location: range.location + delta, length: range.length)
        moved.urlRange = NSRange(location: urlRange.location + delta, length: urlRange.length)
        return moved
    }

    /// 編集(編集前の座標のレンジ)がこの段落を変えうるか。テーブルと同じ規則(`MarkdownTable.isTouched`): 中はもちろん、
    /// 行頭への挿入、行末への挿入、直前の改行の削除も含む。直後の行への挿入は含まない。`HighlightPlan.shifted` と
    /// Live Preview のカードが同じ規則を使う。
    public func isTouched(byEditBefore preEditRange: NSRange) -> Bool {
        preEditRange.location <= NSMaxRange(range) && NSMaxRange(preEditRange) >= range.location
    }
}
