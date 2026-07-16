import AppKit
import Foundation
import Testing
@testable import Laperm

/// テスト用の PNG データ(width×height の単色画像)
func makePNGData(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// 一時ディレクトリに PNG を書き出して URL を返す
func writeTempPNG(name: String, width: Int = 100, height: Int = 50) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LapermTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try makePNGData(width: width, height: height).write(to: url)
    return url
}

@Test @MainActor func defaultLoaderLoadsLocalPNG() async throws {
    let url = try writeTempPNG(name: "a.png", width: 100, height: 50)
    let image = try await DefaultImageLoader().loadImage(for: url)
    #expect(image.size.width == 100)
    #expect(image.size.height == 50)
}

@Test @MainActor func defaultLoaderThrowsOnBrokenData() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LapermTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("broken.png")
    try Data([0x00, 0x01, 0x02]).write(to: url)
    await #expect(throws: (any Error).self) {
        _ = try await DefaultImageLoader().loadImage(for: url)
    }
}

@Test @MainActor func defaultLoaderThrowsOnMissingFile() async throws {
    let url = URL(filePath: "/nonexistent/laperm-missing.png")
    await #expect(throws: (any Error).self) {
        _ = try await DefaultImageLoader().loadImage(for: url)
    }
}
