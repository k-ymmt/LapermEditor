import Foundation

/// Wiki Link(`[[Note]]` / `[[Note|Alias]]` / `[[Note#見出し]]`)1 箇所ぶんの参照情報。
/// 解決(どの Note か)はエディタの外(ホスト)の仕事で、ここには記法に書かれた文字列だけを持つ。
public struct WikiLinkReference: Hashable, Sendable {
    /// 指す Note のタイトル、または `/` を含む Vault ルートからのパス(前後の空白を除く)。
    /// `[[#見出し]]` のように空なら「同じ Note」を指す。
    public var target: String
    /// `#` の後ろの見出し(無ければ nil)。前後の空白は除く。
    public var heading: String?
    /// `|` の後ろの表示文字(無ければ nil)。前後の空白は除く。解決には関わらない。
    public var alias: String?
    /// 記法全体(`[[` から `]]` まで)の UTF-16 レンジ
    public var range: NSRange

    public init(target: String, heading: String? = nil, alias: String? = nil, range: NSRange) {
        self.target = target
        self.heading = heading
        self.alias = alias
        self.range = range
    }

    /// Live Preview でフォーカスの無い行に見える文字(Alias があれば Alias、無ければ `Note` / `Note#見出し`)。
    public var displayText: String {
        if let alias { return alias }
        if let heading { return target.isEmpty ? "#\(heading)" : "\(target)#\(heading)" }
        return target
    }

    /// `[[` と `]]` の間の文字列を分解する。`[`、`]`、改行を含むもの、`|` の左が空(`[[|x]]`)、
    /// 全体が空、ブロック参照(`#^id`)は Wiki Link として扱わず nil。
    /// `unescapesPipes` はテーブルのセルの中(GFM はセル内の `|` を `\|` と書く)で、意味の上では `\|` を `|` として扱う。
    /// レンジは原文のまま。
    static func parse(inner rawInner: String, range: NSRange, unescapesPipes: Bool = false) -> WikiLinkReference? {
        let inner = unescapesPipes ? rawInner.replacingOccurrences(of: "\\|", with: "|") : rawInner
        guard !inner.contains("["), !inner.contains("]"), !inner.contains("\n"), !inner.contains("\r") else { return nil }
        var alias: String?
        var head = Substring(inner)
        if let pipe = inner.firstIndex(of: "|") {
            head = inner[..<pipe]
            alias = inner[inner.index(after: pipe)...].trimmingCharacters(in: .whitespaces)
        }
        var heading: String?
        var target = head
        if let hash = head.firstIndex(of: "#") {
            target = head[..<hash]
            let rest = head[head.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("^") { return nil }
            heading = rest
        }
        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
        if trimmedTarget.isEmpty, heading == nil { return nil }
        if trimmedTarget.isEmpty, heading?.isEmpty == true { return nil }
        // `[[Note|]]` は Alias 無しとして扱う(空の Alias は表示文字が消える)
        if alias?.isEmpty == true { alias = nil }
        return WikiLinkReference(target: trimmedTarget, heading: heading, alias: alias, range: range)
    }
}
