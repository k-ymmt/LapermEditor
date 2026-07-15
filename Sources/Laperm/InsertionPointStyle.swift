/// カーソル(挿入ポイント)の形状。
public enum InsertionPointStyle: Equatable, Sendable {
    /// 標準の縦棒
    case bar
    /// 文字を覆う半透明の矩形(Vim normal モード等)
    case block
    /// 文字下のアンダーライン(Vim replace モード等)
    case underline
}
