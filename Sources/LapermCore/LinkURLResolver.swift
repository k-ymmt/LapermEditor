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
enum URLDestinationResolver {
    static func resolve(
        destination: String, baseURL: URL?, allowedSchemes: Set<String>
    ) -> URL? {
        guard !destination.isEmpty else { return nil }
        // スキーム判定は URL(string:) に頼らず自前で行う(ImageURLResolver の
        // コメント参照: スキームなし相対パスでも URL(string:) は成功しうるため)。
        if let colon = destination.firstIndex(of: ":") {
            let scheme = destination[..<colon].lowercased()
            guard allowedSchemes.contains(scheme) else { return nil }
            return URL(string: destination)
        }
        if destination.hasPrefix("/") {
            return URL(filePath: destination)
        }
        guard let baseURL else { return nil }
        return URL(filePath: destination, relativeTo: baseURL).absoluteURL
    }
}
