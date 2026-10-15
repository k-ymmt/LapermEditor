import Foundation

/// Markdown のリンク / 画像の記法を組み立てる純粋関数(Laperm ADR 0045: Embed は `![](<相対パス>)` を挿入する)。
/// CommonMark の link destination は空白を含めないので、空白(や括弧、`<` `>`)を含むパスは `<…>` で囲む
/// (`![](<../Attachments/Pasted image 20261015123456.png>)`)。パーセント符号化はしない(`ImageURLResolver` は復号しないので、
/// `%20` で書くと今は表示できない)。
public enum MarkdownLinkSyntax {
    /// `[…](…)` / `![…](…)` の括弧の中に書く destination。そのまま書けるパスはそのまま、そうでなければ `<…>` で囲む
    /// (囲いの中の `<` `>` はバックスラッシュで逃がす)。
    public static func destination(_ path: String) -> String {
        // `&copy;` は文字参照として読まれるので `&amp;` で書く(復号は 1 回だけ。`\&` は destination のエスケープにならない。codex review)
        let path = path.replacingOccurrences(of: "&", with: "&amp;")
        guard needsAngleBrackets(path) else { return path }
        var escaped = ""
        escaped.reserveCapacity(path.utf8.count + 2)
        for scalar in path.unicodeScalars {
            switch scalar {
            case "<", ">", "\\": escaped.append("\\")  // `\!` は次の文字のエスケープになる
            default: break
            }
            escaped.unicodeScalars.append(scalar)
        }
        return "<\(escaped)>"
    }

    /// 空白・制御文字・括弧・`<` `>`・`\` を含む、または空のパスは `<…>` で囲まないと destination として書いたとおりに
    /// 読めない。改行を含むパスは囲んでも読めない(ホストが保存前に拒む)。
    static func needsAngleBrackets(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        return path.unicodeScalars.contains { scalar in
            switch scalar {
            case "(", ")", "<", ">", "\\": return true
            default: return scalar.properties.isWhitespace || scalar.value < 0x20 || scalar.value == 0x7F
            }
        }
    }

    /// 画像の記法 `![alt](destination)`。Embed の alt は空(ADR 0045)。
    public static func image(path: String, alt: String = "") -> String {
        "![\(escapedLabel(alt))](\(destination(path)))"
    }

    /// リンクの記法 `[text](destination)`(サイドバーから画像でない Attachment をドラッグしたとき)。
    public static func link(text: String, path: String) -> String {
        "[\(escapedLabel(text))](\(destination(path)))"
    }

    /// 複数の画像の Embed: 1 枚ごとに改行で区切る(各画像が独立した行、ADR 0045)。
    public static func imageEmbeds(paths: [String]) -> String {
        paths.map { image(path: $0) }.joined(separator: "\n")
    }

    /// `[` `]` の中の文字列: 括弧とバックスラッシュを逃がし、`&` は `&amp;`、改行は空白にする。
    static func escapedLabel(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "[", "]", "\\":
                escaped.append("\\")
                escaped.unicodeScalars.append(scalar)
            case "&":
                escaped.append("&amp;")
            case "\n", "\r":
                escaped.append(" ")
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
