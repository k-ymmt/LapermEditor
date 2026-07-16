import Foundation

/// 画像記法の URL 文字列を読み込み可能な URL へ解決する純粋関数。
public enum ImageURLResolver {
    /// - http / https / file スキーム付き → そのまま
    /// - "/" 始まりの絶対パス → file URL
    /// - 相対パス → baseURL に対して解決(baseURL が nil なら解決不能)
    /// - 空文字列・未対応スキーム → nil
    public static func resolve(destination: String, baseURL: URL?) -> URL? {
        guard !destination.isEmpty else { return nil }
        // スキーム判定は URL(string:) に頼らず自前で行う。日本語やスペースを含む
        // 相対パスは URL(string:) が nil を返すため、そちらを先にすると誤判定する。
        if let colon = destination.firstIndex(of: ":") {
            let scheme = destination[..<colon].lowercased()
            switch scheme {
            case "http", "https", "file":
                return URL(string: destination)
            default:
                return nil
            }
        }
        if destination.hasPrefix("/") {
            return URL(filePath: destination)
        }
        guard let baseURL else { return nil }
        return URL(filePath: destination, relativeTo: baseURL).absoluteURL
    }
}
