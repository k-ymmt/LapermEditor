#if os(macOS)
import AppKit
import Testing
import UniformTypeIdentifiers
@testable import LapermEditor
@testable import LapermCore

/// Embed(Laperm ADR 0045): 画像のペースト / ドロップをホストの `AttachmentStore` に保存させ、返った相対パスの `![](…)` を 1 回の
/// Undo で挿入する。ペーストボードの読み方(画像データ → 画像ファイルの URL → テキスト、生データは PNG)もここで確かめる。
@MainActor
final class RecordingAttachmentStore: AttachmentStore {
    var stored: [ImageAttachmentSource] = []
    /// 返すパス(nil を返すと「保存できなかった」)。
    var pathFor: (ImageAttachmentSource) -> String? = { source in
        "../Attachments/\(source.preferredName ?? "Pasted image.png")"
    }
    /// 保存の途中で待たせる(テストがその間に状態を変える)。
    var beforeReturning: (() async -> Void)?
    var allowsInsertion = true

    func store(_ source: ImageAttachmentSource) async -> String? {
        stored.append(source)
        await beforeReturning?()
        return pathFor(source)
    }

    func canInsert() -> Bool { allowsInsertion }
}

private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

@MainActor @Test func embeddingInsertsOneLinePerImageAtTheCaretAndIsOneUndo() async throws {
    let textView = MarkdownTextView()
    let provider = UndoManagerProvider()
    textView.delegate = provider
    let store = RecordingAttachmentStore()
    textView.attachmentStore = store
    textView.string = "Before after"
    textView.setSelectedRange(NSRange(location: 7, length: 0))

    let task = try #require(textView.embedImages([
        ImageAttachmentSource(data: Data([1]), preferredName: nil, typeIdentifier: UTType.png.identifier),
        ImageAttachmentSource(data: Data([2]), preferredName: "photo.heic", typeIdentifier: UTType.heic.identifier),
    ]))
    #expect(await task.value)
    #expect(textView.string == "Before ![](<../Attachments/Pasted image.png>)\n![](../Attachments/photo.heic)after")
    #expect(store.stored.map(\.preferredName) == [nil, "photo.heic"])
    let inserted = "![](<../Attachments/Pasted image.png>)\n![](../Attachments/photo.heic)"
    #expect(textView.selectedRange() == NSRange(location: 7 + (inserted as NSString).length, length: 0), "the caret ends after the embeds")

    provider.manager.undo()
    #expect(textView.string == "Before after", "one undo removes every embed (the files stay)")
}

@MainActor @Test func aDropInsertsAtTheDropLocationAndAFailedStoreInsertsNothing() async throws {
    let textView = MarkdownTextView()
    let store = RecordingAttachmentStore()
    textView.attachmentStore = store
    textView.string = "0123456789"
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let task = try #require(textView.embedImages([ImageAttachmentSource(data: Data(), preferredName: "a.png", typeIdentifier: UTType.png.identifier)], at: 4))
    #expect(await task.value)
    #expect(textView.string == "0123![](../Attachments/a.png)456789")

    store.pathFor = { _ in nil }
    let failed = try #require(textView.embedImages([ImageAttachmentSource(data: Data(), preferredName: "b.png", typeIdentifier: UTType.png.identifier)], at: 0))
    #expect(await failed.value == false)
    #expect(textView.string == "0123![](../Attachments/a.png)456789")

    // 保存を待っている間に文書が短くなった: 末尾に寄せる
    store.pathFor = { _ in "c.png" }
    textView.string = "0123456789"
    store.beforeReturning = { textView.string = "ab" }
    let clamped = try #require(textView.embedImages([ImageAttachmentSource(data: Data(), preferredName: "c.png", typeIdentifier: UTType.png.identifier)], at: 8))
    #expect(await clamped.value)
    #expect(textView.string == "ab![](c.png)")

    // 保存を待っている間に文字列を選んだ: 置き換えずに選択の先頭に入れる
    store.beforeReturning = { textView.setSelectedRange(NSRange(location: 0, length: 2)) }
    textView.string = "ab"
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    let selected = try #require(textView.embedImages([ImageAttachmentSource(data: Data(), preferredName: "c.png", typeIdentifier: UTType.png.identifier)]))
    #expect(await selected.value)
    #expect(textView.string == "![](c.png)ab")

    // 保存の後にホストが拒んだ(別の文書に替わった): 何も挿入しない
    store.beforeReturning = nil
    store.allowsInsertion = false
    textView.string = "ab"
    let refused = try #require(textView.embedImages([ImageAttachmentSource(data: Data(), preferredName: "c.png", typeIdentifier: UTType.png.identifier)]))
    #expect(await refused.value == false)
    #expect(textView.string == "ab")
    store.allowsInsertion = true

    textView.attachmentStore = nil
    #expect(textView.embedImages([ImageAttachmentSource(data: Data(), preferredName: "d.png", typeIdentifier: UTType.png.identifier)]) == nil,
            "without a store the editor does not embed")
}

@MainActor @Test func pasteboardImagesComeBeforeFileURLsAndText() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("LapermEditorTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    // 画像データと URL の文字列(ブラウザで画像をコピーした形): 画像データだけを使い、名前は無い
    pasteboard.clearContents()
    let tiff = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }.tiffRepresentation!
    let item = NSPasteboardItem()
    item.setData(tiff, forType: .tiff)
    item.setString("https://example.com/image.png", forType: .string)
    pasteboard.writeObjects([item])
    #expect(ImageSourceReader.hasImages(pasteboard))
    var sources = await ImageSourceReader.imageSources(from: pasteboard)
    #expect(sources.count == 1)
    #expect(sources.first?.preferredName == nil)
    #expect(sources.first?.typeIdentifier == UTType.png.identifier)
    #expect(sources.first?.data.prefix(8) == pngSignature, "raw clipboard data (TIFF) is fixed to PNG")

    // PNG データはそのまま
    let png = makePNGData(width: 3, height: 3)
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    sources = await ImageSourceReader.imageSources(from: pasteboard)
    #expect(sources.first?.data == png)

    // 画像ファイルの URL(Finder でコピー): 名前と形式はそのまま
    let url = try writeTempPNG(name: "Diagram 1.png")
    pasteboard.clearContents()
    pasteboard.writeObjects([url as NSURL])
    #expect(ImageSourceReader.hasImages(pasteboard))
    sources = await ImageSourceReader.imageSources(from: pasteboard)
    #expect(sources.map(\.preferredName) == ["Diagram 1.png"])
    #expect(sources.first?.typeIdentifier == UTType.png.identifier)
    #expect(sources.first?.data == (try Data(contentsOf: url)))

    // 画像でないファイルの URL とテキストだけ: 画像は無い
    let text = url.deletingLastPathComponent().appending(path: "notes.txt")
    try Data("x".utf8).write(to: text)
    pasteboard.clearContents()
    pasteboard.writeObjects([text as NSURL])
    #expect(!ImageSourceReader.hasImages(pasteboard))
    pasteboard.clearContents()
    pasteboard.setString("plain", forType: .string)
    #expect(!ImageSourceReader.hasImages(pasteboard))
    #expect(await ImageSourceReader.imageSources(from: pasteboard).isEmpty)
}

@MainActor @Test func aStoreAddsImageTypesToTheReadableTypesAndAHandlerItsOwn() {
    let textView = MarkdownTextView()
    #expect(!textView.readablePasteboardTypes.contains(.png))
    let store = RecordingAttachmentStore()  // weak に持たれるので、ここで生かしておく
    textView.attachmentStore = store
    #expect(textView.readablePasteboardTypes.contains(.png))
    #expect(textView.readablePasteboardTypes.contains(.tiff))
    #expect(textView.readablePasteboardTypes.contains(.fileURL))
    let custom = NSPasteboard.PasteboardType("app.example.item")
    #expect(!textView.readablePasteboardTypes.contains(custom))
    textView.droppedItemHandler = DroppedItemHandler(typeIdentifiers: ["app.example.item"]) { _ in nil }
    #expect(textView.readablePasteboardTypes.contains(custom))
}

@MainActor @Test func droppedItemDataIsCollectedPerItemAndInsertedAsText() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("LapermEditorTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let handler = DroppedItemHandler(typeIdentifiers: ["app.example.item"]) { items in
        items.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " + ")
    }
    pasteboard.clearContents()
    let first = NSPasteboardItem()
    first.setData(Data("one".utf8), forType: NSPasteboard.PasteboardType("app.example.item"))
    let second = NSPasteboardItem()
    second.setData(Data("two".utf8), forType: NSPasteboard.PasteboardType("app.example.item"))
    let other = NSPasteboardItem()
    other.setString("text", forType: .string)
    pasteboard.writeObjects([first, second, other])
    let items = ImageSourceReader.droppedItemData(from: pasteboard, for: handler)
    #expect(items.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])

    let textView = MarkdownTextView()
    textView.string = "ab"
    #expect(textView.insertDroppedText(handler.text(items) ?? "", at: 1))
    #expect(textView.string == "aone + twob")
    #expect(textView.selectedRange() == NSRange(location: 10, length: 0))
}

@MainActor @Test func theSwiftUIViewHandsTheStoreAndTheHandlerToTheTextView() {
    let textView = MarkdownTextView()
    let store = RecordingAttachmentStore()
    let view = MarkdownEditorView(text: .constant(""))
        .attachmentStore(store)
        .onDropItems(ofTypes: ["app.example.item"]) { _ in "x" }
    view.apply(to: textView)
    #expect(textView.attachmentStore === store)
    #expect(textView.droppedItemHandler?.typeIdentifiers == ["app.example.item"])
    MarkdownEditorView(text: .constant("")).apply(to: textView)
    #expect(textView.attachmentStore == nil)
    #expect(textView.droppedItemHandler == nil)
}
#endif
