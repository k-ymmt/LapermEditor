#if canImport(UIKit)
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import LapermEditor
@testable import LapermCore

/// Embed(Laperm ADR 0045)の iOS 版: ホストの `AttachmentStore` に保存させて `![](…)` を挿入し、1 回の Undo で戻る。項目
/// (ペーストボード / ドロップの `NSItemProvider`)の読み方: 名前の無い生データは PNG に、名前のあるものはそのまま。
@MainActor
final class RecordingAttachmentStore: AttachmentStore {
    var stored: [ImageAttachmentSource] = []
    var pathFor: (ImageAttachmentSource) -> String? = { source in "Attachments/\(source.preferredName ?? "Pasted image.png")" }

    func embed(_ source: ImageAttachmentSource) async -> String? {
        stored.append(source)
        return pathFor(source).map { MarkdownLinkSyntax.image(path: $0) }
    }
}

private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

@MainActor @Test func embeddingInsertsAtTheCaretAndIsOneUndo() async throws {
    let textView = makeLaidOutTextView("Before after")
    let window = hostInWindow(textView)
    defer { window.isHidden = true }
    let store = RecordingAttachmentStore()
    textView.attachmentStore = store
    textView.selectedRange = NSRange(location: 7, length: 0)

    let task = try #require(textView.embedImages([
        ImageAttachmentSource(data: Data([1]), preferredName: nil, typeIdentifier: UTType.png.identifier),
        ImageAttachmentSource(data: Data([2]), preferredName: "IMG_0001.HEIC", typeIdentifier: UTType.heic.identifier),
    ]))
    #expect(await task.value)
    #expect(textView.text == "Before ![](<Attachments/Pasted image.png>)\n![](Attachments/IMG_0001.HEIC)after")
    textView.undoManager?.undo()
    #expect(textView.text == "Before after")

    // ドロップは落とした位置に
    let dropped = try #require(textView.embedImages([ImageAttachmentSource(data: Data(), preferredName: "a.png", typeIdentifier: UTType.png.identifier)], at: 0))
    #expect(await dropped.value)
    #expect(textView.text.hasPrefix("![](Attachments/a.png)Before"))

    textView.attachmentStore = nil
    #expect(textView.embedImages([ImageAttachmentSource(data: Data(), preferredName: "b.png", typeIdentifier: UTType.png.identifier)]) == nil)
}

@Test func itemProvidersWithNamesKeepTheirFormatAndNamelessDataBecomesPNG() async throws {
    let jpeg = UIImage(data: makePNGData(width: 2, height: 2))!.jpegData(compressionQuality: 0.9)!
    // Photos からのドラッグ: 名前付きの JPEG はそのまま
    let named = NSItemProvider(item: jpeg as NSData, typeIdentifier: UTType.jpeg.identifier)
    named.suggestedName = "IMG_0001"
    // クリップボードの生データ(名前なし): PNG にする
    let raw = NSItemProvider(item: jpeg as NSData, typeIdentifier: UTType.jpeg.identifier)
    // 文字列だけの項目は飛ばす
    let text = NSItemProvider(item: "https://example.com/x.png" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)
    #expect(ImageSourceReader.hasImages([named, raw, text]))
    #expect(!ImageSourceReader.hasImages([text]))

    let sources = await ImageSourceReader.imageSources(from: [named, raw, text])
    #expect(sources.count == 2)
    #expect(sources[0].preferredName == "IMG_0001.jpeg")
    #expect(sources[0].typeIdentifier == UTType.jpeg.identifier)
    #expect(sources[0].data == jpeg)
    #expect(sources[1].preferredName == nil)
    #expect(sources[1].typeIdentifier == UTType.png.identifier)
    #expect(sources[1].data.prefix(8) == pngSignature)

    // 画像ファイルの URL: 名前と形式はファイルから
    let url = try writeTempPNG(name: "Diagram 1.png")
    let file = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
    let fromFile = await ImageSourceReader.imageSources(from: [file])
    #expect(fromFile.map(\.preferredName) == ["Diagram 1.png"])
    #expect(fromFile.first?.data == (try Data(contentsOf: url)))

    // 名前付きで HEIC と PNG の両方を持つ provider: 名前の形式(JPEG)のバイト列を選ぶ(PNG を `.jpeg` の名前で保存しない)
    let both = NSItemProvider()
    both.suggestedName = "IMG_0002.jpeg"
    both.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
        completion(makePNGData(width: 2, height: 2), nil)
        return nil
    }
    both.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
        completion(jpeg, nil)
        return nil
    }
    let chosen = await ImageSourceReader.imageSources(from: [both])
    #expect(chosen.first?.typeIdentifier == UTType.jpeg.identifier)
    #expect(chosen.first?.data == jpeg)
    #expect(chosen.first?.preferredName == "IMG_0002.jpeg")

    // 画像でないファイルの URL(PDF)だけ: 画像の経路に入れない(通常のペーストに任せる)
    let pdf = NSItemProvider(item: URL(filePath: "/tmp/x.pdf") as NSURL, typeIdentifier: UTType.fileURL.identifier)
    pdf.suggestedName = "x.pdf"
    #expect(!ImageSourceReader.hasImages([pdf]))
}

@Test func droppedItemDataIsCollectedPerItem() async {
    let handler = DroppedItemHandler(typeIdentifiers: ["app.example.item"]) { items in items.count.description }
    let one = NSItemProvider(item: Data("one".utf8) as NSData, typeIdentifier: "app.example.item")
    let two = NSItemProvider(item: Data("two".utf8) as NSData, typeIdentifier: "app.example.item")
    let text = NSItemProvider(item: "x" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)
    let items = await ImageSourceReader.droppedItemData(from: [one, text, two], for: handler)
    #expect(items.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
}

@MainActor @Test func pasteIsOfferedForAnImageOnlyPasteboardWhenThereIsAStore() {
    let textView = makeLaidOutTextView("")
    let pasteboard = UIPasteboard.general
    let saved = pasteboard.items
    defer { pasteboard.items = saved }
    pasteboard.image = UIImage(data: makePNGData(width: 2, height: 2))
    #expect(MarkdownTextView.pasteboardHasImages(pasteboard))
    let store = RecordingAttachmentStore()  // weak に持たれるので、ここで生かしておく
    textView.attachmentStore = store
    #expect(textView.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
}
#endif
