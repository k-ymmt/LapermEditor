/// ホストが Wiki Link を解決した結果。エディタは色分け(Unresolved)にだけ使い、解決先そのものは知らない。
public enum WikiLinkResolution: Hashable, Sendable {
    /// 指す Note(または Attachment)がある。通常のリンク色。
    case resolved
    /// 指す Note が無い。Theme の Unresolved の色。
    case unresolved
    /// まだ分からない(索引の作成中など)。通常のリンク色(作成中に全部が Unresolved 色になる瞬間を作らない)。
    case unknown
}
