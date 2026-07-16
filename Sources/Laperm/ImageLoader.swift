import AppKit
import ImageIO

/// 画像の取得・デコードを差し替え可能にするプロトコル。
/// NSImage は Sendable でないため @MainActor プロトコルとし、実装側は
/// ダウンロード・デコードを Sendable な型(Data / CGImage)でバックグラウンド処理してから
/// main で NSImage 化すること(DefaultImageLoader が参照実装)。
@MainActor
public protocol ImageLoader: AnyObject {
    func loadImage(for url: URL) async throws -> NSImage
}

public enum ImageLoadError: Error {
    case decodingFailed
}

/// 内蔵ローダー。file URL はローカル読み込み、http(s) は URLSession。
/// メモリキャッシュ(NSCache)付き。デコードまで detached タスクで行い、
/// メインスレッドをブロックしない。
@MainActor
public final class DefaultImageLoader: ImageLoader {
    private let cache = NSCache<NSURL, NSImage>()

    public init() {}

    public func loadImage(for url: URL) async throws -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let cgImage = try await Self.decode(url: url)
        // ピクセル寸法をポイントとして扱う(高 DPI 画像は原寸の2倍で扱われるが
        // maxHeight クランプで実害を抑える v1 の割り切り)
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// 取得とデコードをバックグラウンドで行い、Sendable な CGImage で受け渡す。
    private static func decode(url: URL) async throws -> CGImage {
        let data: Data
        if url.isFileURL {
            data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: url)
            }.value
        } else {
            (data, _) = try await URLSession.shared.data(from: url)
        }
        return try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw ImageLoadError.decodingFailed }
            return image
        }.value
    }
}
