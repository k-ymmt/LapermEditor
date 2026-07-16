import Foundation

/// 画像記法 1 箇所ぶんの参照情報。UI 層のプレビュー表示が消費する。
public struct ImageReference: Hashable, Sendable {
    /// alt テキスト(装飾を除いたプレーンテキスト)
    public var altText: String
    /// 記法に書かれた URL 文字列(未解決)
    public var destination: String
    /// `![alt](url)` 全体の UTF-16 レンジ
    public var range: NSRange
    /// 記法を含む改行区切りの行(テキスト段落)のレンジ。paragraphSpacing の適用先。
    public var paragraphRange: NSRange
    /// テーブルセル内の画像(v1 ではプレビュー対象外)
    public var isInsideTable: Bool

    public init(
        altText: String,
        destination: String,
        range: NSRange,
        paragraphRange: NSRange,
        isInsideTable: Bool = false
    ) {
        self.altText = altText
        self.destination = destination
        self.range = range
        self.paragraphRange = paragraphRange
        self.isInsideTable = isInsideTable
    }
}
