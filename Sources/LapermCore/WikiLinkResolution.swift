import Foundation

/// ホストが Wiki Link を解決した結果。エディタは色分け(Unresolved)と、埋め込み `![[image.png]]` の画像の場所にだけ使い、
/// 解決先そのものは知らない。
public enum WikiLinkResolution: Hashable, Sendable {
    /// 指す Note がある。通常のリンク色。
    case resolved
    /// 指す Attachment があり、その場所(file URL)。通常のリンク色。素の画像の埋め込み(`WikiLinkReference.isEmbed`)は
    /// この URL の画像をプレビューする(Laperm ADR 0054)。
    case attachment(URL)
    /// 指す Note(Attachment)が無い。Theme の Unresolved の色。
    case unresolved
    /// まだ分からない(索引の作成中など)。通常のリンク色(作成中に全部が Unresolved 色になる瞬間を作らない)。
    case unknown
}
