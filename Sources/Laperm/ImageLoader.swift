#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import ImageIO

/// 画像の取得・デコードを差し替え可能にするプロトコル。
/// NSImage / UIImage は Sendable でないため @MainActor プロトコルとし、実装側は
/// ダウンロード・デコードを Sendable な型(Data / CGImage)でバックグラウンド処理してから
/// main で PlatformImage 化すること(DefaultImageLoader が参照実装)。
@MainActor
public protocol ImageLoader: AnyObject {
    func loadImage(for url: URL) async throws -> PlatformImage
}

public enum ImageLoadError: Error {
    case decodingFailed
}

/// 内蔵ローダー。file URL はローカル読み込み、http(s) は URLSession。
/// メモリキャッシュ(NSCache)付き。デコードまで detached タスクで行い、
/// メインスレッドをブロックしない。
@MainActor
public final class DefaultImageLoader: ImageLoader {
    /// デコード後の長辺の上限(ピクセル)。プレビューは maxHeight(既定 320pt)以下に
    /// 縮小表示されるため、原寸(12MP 写真で約 48MB)を保持・再サンプリングし続ける必要はない。
    /// Retina でコンテナ幅いっぱいに表示しても足りる程度に取る。
    public nonisolated static let maxPixelSize = 2048
    /// メモリキャッシュの上限(デコード済みピクセルのバイト数換算)
    public nonisolated static let cacheCostLimit = 128 * 1024 * 1024

    private let cache = NSCache<NSURL, PlatformImage>()

    public init() {
        cache.totalCostLimit = Self.cacheCostLimit
    }

    public func loadImage(for url: URL) async throws -> PlatformImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let cgImage = try await Self.decode(url: url)
        // ピクセル寸法をポイントとして扱う(高 DPI 画像は原寸の2倍で扱われるが
        // maxHeight クランプで実害を抑える v1 の割り切り)
        #if canImport(AppKit)
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        #endif
        cache.setObject(image, forKey: url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// 取得とデコードをバックグラウンドで行い、Sendable な CGImage で受け渡す。
    /// デコードは maxPixelSize に収まるサムネイルとして行う(ImageIO がダウンサンプリング
    /// しながらデコードするため、原寸を一度メモリに展開しない)。EXIF の向きも適用する。
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
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { throw ImageLoadError.decodingFailed }
            return image
        }.value
    }
}

