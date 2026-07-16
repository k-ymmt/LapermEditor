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

import LapermCore

/// 完了タイミングを外から制御できるモックローダー
@MainActor
final class MockImageLoader: ImageLoader {
    var pending: [(url: URL, continuation: CheckedContinuation<NSImage, any Error>)] = []
    var loadCount = 0

    func loadImage(for url: URL) async throws -> NSImage {
        loadCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((url, continuation))
        }
    }

    func finishAll(with result: Result<NSImage, any Error>) {
        let waiting = pending
        pending = []
        for entry in waiting { entry.continuation.resume(with: result) }
    }
}

private func makeReference(
    destination: String, location: Int = 0, isInsideTable: Bool = false
) -> ImageReference {
    ImageReference(
        altText: "alt", destination: destination,
        range: NSRange(location: location, length: 10),
        paragraphRange: NSRange(location: location, length: 11),
        isInsideTable: isInsideTable)
}

/// 非同期の状態遷移を待つヘルパー
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

@Test @MainActor func startsLoadingAndTransitionsToLoaded() async throws {
    let loader = MockImageLoader()
    let controller = ImagePreviewController()
    controller.loader = loader
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    var stateChanged = false
    controller.onStateChange = { stateChanged = true }

    let ref = makeReference(destination: "a.png")
    controller.update(references: [ref])
    #expect(controller.state(for: ref) == .loading)

    try await waitUntil { loader.pending.count == 1 }
    let image = NSImage(size: NSSize(width: 10, height: 10))
    loader.finishAll(with: .success(image))
    try await waitUntil { controller.state(for: ref) == .loaded(image) }
    #expect(stateChanged)
}

@Test @MainActor func failedLoadTransitionsToFailed() async throws {
    let loader = MockImageLoader()
    let controller = ImagePreviewController()
    controller.loader = loader
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let ref = makeReference(destination: "a.png")
    controller.update(references: [ref])
    try await waitUntil { loader.pending.count == 1 }
    loader.finishAll(with: .failure(ImageLoadError.decodingFailed))
    try await waitUntil { controller.state(for: ref) == .failed }
}

@Test @MainActor func unresolvableDestinationFailsImmediately() {
    let controller = ImagePreviewController()  // baseURL なし
    let ref = makeReference(destination: "relative.png")
    controller.update(references: [ref])
    #expect(controller.state(for: ref) == .failed)
}

@Test @MainActor func remoteDisallowedFailsImmediately() {
    let controller = ImagePreviewController()  // allowsRemoteImages: false
    let ref = makeReference(destination: "https://example.com/a.png")
    controller.update(references: [ref])
    #expect(controller.state(for: ref) == .failed)
}

@Test @MainActor func remoteAllowedStartsLoading() {
    let controller = ImagePreviewController()
    controller.loader = MockImageLoader()
    controller.options = ImagePreviewOptions(allowsRemoteImages: true)
    let ref = makeReference(destination: "https://example.com/a.png")
    controller.update(references: [ref])
    #expect(controller.state(for: ref) == .loading)
}

@Test @MainActor func removedReferenceCancelsAndDiscardsResult() async throws {
    let loader = MockImageLoader()
    let controller = ImagePreviewController()
    controller.loader = loader
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let ref = makeReference(destination: "a.png")
    controller.update(references: [ref])
    try await waitUntil { loader.pending.count == 1 }
    // 編集で画像が消えた
    controller.update(references: [])
    #expect(controller.state(for: ref) == nil)
    // 遅れて届いた結果は反映されない
    loader.finishAll(with: .success(NSImage(size: NSSize(width: 1, height: 1))))
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.state(for: ref) == nil)
}

@Test @MainActor func sameDestinationTwiceLoadsOnce() async throws {
    let loader = MockImageLoader()
    let controller = ImagePreviewController()
    controller.loader = loader
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let ref1 = makeReference(destination: "a.png", location: 0)
    let ref2 = makeReference(destination: "a.png", location: 100)
    controller.update(references: [ref1, ref2])
    try await waitUntil { loader.pending.count == 1 }
    #expect(loader.loadCount == 1)
}

@Test @MainActor func tableImagesAndDisabledOptionAreFilteredOut() {
    let controller = ImagePreviewController()
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let tableRef = makeReference(destination: "a.png", isInsideTable: true)
    controller.update(references: [tableRef])
    #expect(controller.references.isEmpty)

    controller.options = ImagePreviewOptions(isEnabled: false, baseURL: URL(filePath: "/docs/"))
    controller.update(references: [makeReference(destination: "b.png")])
    #expect(controller.references.isEmpty)
}

@Test @MainActor func displaySizeFitsWidthAndMaxHeight() {
    let controller = ImagePreviewController()
    controller.loader = MockImageLoader()  // 実 IO を避けて状態を決定的にする
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"), maxHeight: 320)
    let ref = makeReference(destination: "a.png")
    controller.update(references: [ref])
    // loading プレースホルダー
    #expect(controller.displaySize(for: ref, containerWidth: 500).height
        == ImagePreviewController.loadingHeight)

    // 原寸 1000×400 → 幅 500 にフィットで 500×200
    controller.setStateForTesting(.loaded(NSImage(size: NSSize(width: 1000, height: 400))),
                                  destination: "a.png")
    #expect(controller.displaySize(for: ref, containerWidth: 500)
        == CGSize(width: 500, height: 200))

    // 原寸 100×800 → maxHeight 320 で 40×320
    controller.setStateForTesting(.loaded(NSImage(size: NSSize(width: 100, height: 800))),
                                  destination: "a.png")
    #expect(controller.displaySize(for: ref, containerWidth: 500)
        == CGSize(width: 40, height: 320))

    // 小さい画像は拡大しない
    controller.setStateForTesting(.loaded(NSImage(size: NSSize(width: 60, height: 30))),
                                  destination: "a.png")
    #expect(controller.displaySize(for: ref, containerWidth: 500)
        == CGSize(width: 60, height: 30))
}

@Test @MainActor func reservedHeightsSumImagesPerParagraph() {
    let controller = ImagePreviewController()
    controller.loader = MockImageLoader()  // 実 IO を避けて状態を決定的にする
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    let ref1 = makeReference(destination: "a.png", location: 0)
    var ref2 = makeReference(destination: "b.png", location: 12)
    ref2.paragraphRange = ref1.paragraphRange  // 同一段落
    controller.update(references: [ref1, ref2])
    controller.setStateForTesting(.loaded(NSImage(size: NSSize(width: 100, height: 50))),
                                  destination: "a.png")
    // a: 50 + 8, b(loading): 80 + 8
    let heights = controller.reservedHeights(containerWidth: 500)
    #expect(heights == [ref1.paragraphRange: CGFloat(50 + 8 + 80 + 8)])
}

@Test @MainActor func applySpacingsSetsParagraphStyleAndMarker() {
    let contentStorage = NSTextContentStorage()
    let storage = NSTextStorage(string: "![a](a.png)\nnext line")
    contentStorage.textStorage = storage
    let controller = ImagePreviewController()
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    var ref = makeReference(destination: "a.png")
    ref.paragraphRange = NSRange(location: 0, length: 12)  // "![a](a.png)\n"
    controller.update(references: [ref])  // → loading (高さ 80 + 8)

    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)

    let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        as? NSParagraphStyle
    #expect(style?.paragraphSpacing == 88)
    let marker = storage.attribute(
        ImagePreviewController.spacingAttribute, at: 0, effectiveRange: nil) as? CGFloat
    #expect(marker == 88)
    // 隣の段落には付かない
    #expect(storage.attribute(.paragraphStyle, at: 15, effectiveRange: nil) == nil)
}

@Test @MainActor func applySpacingsRemovesStaleSpacing() {
    let contentStorage = NSTextContentStorage()
    let storage = NSTextStorage(string: "![a](a.png)\nnext line")
    contentStorage.textStorage = storage
    let controller = ImagePreviewController()
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    var ref = makeReference(destination: "a.png")
    ref.paragraphRange = NSRange(location: 0, length: 12)
    controller.update(references: [ref])
    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)

    // 画像が消えたら spacing も消える
    controller.update(references: [])
    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)
    #expect(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) == nil)
    #expect(storage.attribute(
        ImagePreviewController.spacingAttribute, at: 0, effectiveRange: nil) == nil)
}

@Test @MainActor func applySpacingsIsIdempotentWhenUnchanged() {
    let contentStorage = NSTextContentStorage()
    let storage = NSTextStorage(string: "![a](a.png)\nnext")
    contentStorage.textStorage = storage
    let controller = ImagePreviewController()
    controller.options = ImagePreviewOptions(baseURL: URL(filePath: "/docs/"))
    var ref = makeReference(destination: "a.png")
    ref.paragraphRange = NSRange(location: 0, length: 12)
    controller.update(references: [ref])
    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)

    // 変化がなければ 2 回目は編集イベントを発生させない
    var edited = false
    let observer = NotificationCenter.default.addObserver(
        forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
    ) { _ in edited = true }
    defer { NotificationCenter.default.removeObserver(observer) }
    controller.applySpacings(contentStorage: contentStorage, containerWidth: 500)
    #expect(!edited)
}

@Test @MainActor func textViewAppliesSpacingForLocalImageEndToEnd() async throws {
    let url = try writeTempPNG(name: "sample.png", width: 100, height: 50)
    let textView = MarkdownTextView()
    // ヘッドレスでは frame がゼロのまま。コンテナ幅がゼロだと loaded サイズが
    // プレースホルダー扱いになるため、明示的に幅を与える。
    textView.setFrameSize(NSSize(width: 500, height: 300))
    textView.imagePreviewController.options =
        ImagePreviewOptions(baseURL: url.deletingLastPathComponent())
    textView.string = "![sample](sample.png)\n\nafter"
    textView.highlightAll()
    guard let storage = textView.textStorage else {
        Issue.record("textStorage missing")
        return
    }
    // 非同期ロード完了 → onStateChange → spacing 再適用を待つ
    try await waitUntil {
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
        return style?.paragraphSpacing == 50 + ImagePreviewController.padding
    }
}
