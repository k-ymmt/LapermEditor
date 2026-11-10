import Foundation

/// リンク記法・ベア URL の URL 文字列を開ける URL へ解決する純粋関数。
/// 規則は ImageURLResolver と同じで、許可スキームに mailto が加わる。
public enum LinkURLResolver {
    public static func resolve(destination: String, baseURL: URL?) -> URL? {
        URLDestinationResolver.resolve(
            destination: destination, baseURL: baseURL,
            allowedSchemes: ["http", "https", "file", "mailto"])
    }
}

/// ImageURLResolver / LinkURLResolver の共通実装。
/// - 許可スキーム付き → そのまま
/// - "/" 始まりの絶対パス → file URL
/// - 相対パス → baseURL に対して解決(baseURL が nil なら解決不能)
/// - 空文字列・未対応スキーム → nil
/// パス(絶対・相対)はパーセント符号化を復号して解決する(`![](Attachments/My%20Image.png)` は `My Image.png`、CommonMark の
/// 普通の書き方。Laperm ADR 0054)。復号した名前のファイルが無く、書かれたままの綴りのファイルがあればそちら(`%20` を名前に
/// 含むファイル)。どちらも無ければ復号した方(無いものは無い)。
enum URLDestinationResolver {
    static func resolve(
        destination: String, baseURL: URL?, allowedSchemes: Set<String>
    ) -> URL? {
        guard !destination.isEmpty else { return nil }
        // スキーム判定は URL(string:) に頼らず自前で行う(ImageURLResolver の
        // コメント参照: スキームなし相対パスでも URL(string:) は成功しうるため)。
        // RFC 3986 のスキーム(`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`)の後ろの `:` だけがスキームの区切り。パスの中の `:`
        // (`x.epub#epubcfi(/6/4!/4/2,/1:0,/1:15)`、Laperm ADR 0056)はスキームではない
        if let colon = destination.firstIndex(of: ":"), isScheme(destination[..<colon]) {
            let scheme = destination[..<colon].lowercased()
            guard allowedSchemes.contains(scheme) else { return nil }
            return URL(string: destination)
        }
        if destination.hasPrefix("/") {
            return preferringDecoded(destination) { URL(filePath: $0) }
        }
        guard let baseURL else { return nil }
        return preferringDecoded(destination) { URL(filePath: $0, relativeTo: baseURL).absoluteURL }
    }

    static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return text.unicodeScalars.dropFirst().allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "+" || scalar == "-" || scalar == ".")
        }
    }

    /// 復号した綴りの URL。復号で変わり、復号した方が無くて書かれたままの方がディスクにあれば、書かれたままの URL。
    private static func preferringDecoded(_ destination: String, make: (String) -> URL) -> URL {
        guard let decoded = destination.removingPercentEncoding, decoded != destination, !decoded.isEmpty else {
            return make(destination)
        }
        let decodedURL = make(decoded)
        let rawURL = make(destination)
        let manager = FileManager.default
        if !manager.fileExists(atPath: decodedURL.path(percentEncoded: false)), manager.fileExists(atPath: rawURL.path(percentEncoded: false)) {
            return rawURL
        }
        return decodedURL
    }
}
