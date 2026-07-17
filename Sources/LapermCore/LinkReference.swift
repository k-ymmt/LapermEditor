import Foundation

/// リンク 1 箇所ぶんの参照情報。UI 層のクリック処理が消費する。
public struct LinkReference: Hashable, Sendable {
    /// リンクテキスト(装飾を除いたプレーンテキスト。ベア URL では URL 自身)
    public var text: String
    /// 記法に書かれた URL 文字列(未解決)
    public var destination: String
    /// 記法全体の UTF-16 レンジ(ベア URL では URL 自身のレンジ)
    public var range: NSRange

    public init(text: String, destination: String, range: NSRange) {
        self.text = text
        self.destination = destination
        self.range = range
    }
}
