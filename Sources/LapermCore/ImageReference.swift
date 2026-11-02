import Foundation

/// 画像記法(`![alt](url)`、または Wiki 記法の埋め込み `![[image.png]]`)1 箇所ぶんの参照情報。UI 層のプレビュー表示が消費する。
public struct ImageReference: Hashable, Sendable {
    /// alt テキスト(装飾を除いたプレーンテキスト)。埋め込みでは空。
    public var altText: String
    /// 記法に書かれた URL 文字列(未解決)。埋め込みでは `wikiTarget` と同じ名前で、プレビューの前にホストの解決で URL に置き換わる。
    public var destination: String
    /// `![alt](url)` / `![[…]]` 全体の UTF-16 レンジ
    public var range: NSRange
    /// 記法を含む改行区切りの行(テキスト段落)のレンジ。paragraphSpacing の適用先。
    public var paragraphRange: NSRange
    /// テーブルセル内の画像(v1 ではプレビュー対象外)
    public var isInsideTable: Bool
    /// `![[image.png]]`(Laperm ADR 0054)なら記法に書かれた名前 / パス。`destination` はホストの Wiki Link の解決
    /// (`WikiLinkResolution.attachment(URL)`)で決まり、解決できなければプレビューしない。`![alt](url)` では nil。
    public var wikiTarget: String?

    public init(
        altText: String,
        destination: String,
        range: NSRange,
        paragraphRange: NSRange,
        isInsideTable: Bool = false,
        wikiTarget: String? = nil
    ) {
        self.altText = altText
        self.destination = destination
        self.range = range
        self.paragraphRange = paragraphRange
        self.isInsideTable = isInsideTable
        self.wikiTarget = wikiTarget
    }
}
