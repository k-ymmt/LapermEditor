import Foundation
import LapermCore
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Embed する画像 1 枚ぶん(Laperm ADR 0045): ペースト / ドロップ / ホストの Command が集めたデータと、分かっていれば元の名前。
public struct ImageAttachmentSource: Sendable {
    /// 画像のバイト列(変換はしない。クリップボードの生データだけは PNG にしてある)。
    public var data: Data
    /// 元のファイル名(拡張子付き)。クリップボードの生データなど名前が無いものは nil で、ホストが名前を付ける
    /// (Laperm は `Pasted image yyyyMMddHHmmss.png`)。
    public var preferredName: String?
    /// `data` の型(UTType の識別子。`public.png` など)。
    public var typeIdentifier: String

    public init(data: Data, preferredName: String?, typeIdentifier: String) {
        self.data = data
        self.preferredName = preferredName
        self.typeIdentifier = typeIdentifier
    }

    /// `typeIdentifier` の拡張子(`png`)。分からなければ nil。
    public var preferredFilenameExtension: String? {
        UTType(typeIdentifier)?.preferredFilenameExtension
    }
}

/// ホスト(Laperm)が Embed の保存を引き受けるプロトコル(ADR 0045: 保存先のフォルダ、名前の衝突、協調した書き込みは Vault の
/// 事情なのでホストが担い、挿入位置と Undo はエディタが担う)。`store` は保存したファイルの、文書(Note)のあるフォルダからの
/// 相対パスを返す。エディタはそれを `![](<…>)` にしてキャレット(ドロップなら落とした位置)に挿入する。保存できなければ nil
/// (何も挿入しない。知らせるのはホスト)。
@MainActor
public protocol AttachmentStore: AnyObject {
    func store(_ source: ImageAttachmentSource) async -> String?
}

/// ホスト独自のペーストボードの型(Laperm のサイドバーの行)のドロップを文字列にする(ADR 0045: Attachment の行をエディタへ
/// ドラッグすると参照だけを挿入する)。`typeIdentifiers` のどれかを持つドロップはエディタが受け、その型のデータ(項目ごとに 1 つ)
/// を `text` に渡し、返った文字列を落とした位置に挿入する。nil なら何も挿入しない(ドロップは消費する)。
public struct DroppedItemHandler: Sendable {
    public var typeIdentifiers: [String]
    public var text: @MainActor @Sendable ([Data]) -> String?

    public init(typeIdentifiers: [String], text: @escaping @MainActor @Sendable ([Data]) -> String?) {
        self.typeIdentifiers = typeIdentifiers
        self.text = text
    }
}

/// 保存 → 挿入の流れ(両プラットフォームの `MarkdownTextView` が共有する)。
@MainActor
enum ImageEmbedder {
    /// `sources` を順にホストに保存させ、返ったパスの `![](…)` を 1 つの編集(1 回の Undo)で挿入する。`location` が nil なら
    /// 保存が終わった時点の選択範囲に(ペースト)、あればその位置に(ドロップ。待っている間に文書が短くなっていれば末尾に寄せる)。
    /// 何か挿入できたら true。
    static func embed(
        _ sources: [ImageAttachmentSource],
        store: any AttachmentStore,
        at location: Int?,
        textLength: () -> Int,
        selection: () -> NSRange,
        perform: (EditCommand) -> Bool
    ) async -> Bool {
        var paths: [String] = []
        for source in sources {
            if let path = await store.store(source) { paths.append(path) }
        }
        guard !paths.isEmpty else { return false }
        let text = MarkdownLinkSyntax.imageEmbeds(paths: paths)
        let range = location.map { NSRange(location: min($0, textLength()), length: 0) } ?? selection()
        let caret = NSRange(location: range.location + (text as NSString).length, length: 0)
        return perform(EditCommand(replacementRange: range, replacementString: text, selectedRange: caret))
    }
}

/// ペーストボード / ドラッグの項目から Embed する画像を取り出す(ADR 0045: 画像データ → 画像ファイルの URL → テキストの順で
/// 最初に見つかったものだけを使う。ブラウザで画像をコピーすると画像と URL が同時に載るので、URL を貼らない)。
/// クリップボードの生データ(名前の無い画像)は PNG に固定し(macOS では TIFF が中間形式で利用者のファイルではない)、名前の
/// あるもの(ファイル、Photos や Files からのドラッグ)は形式も名前もそのまま。`NSItemProvider` を読む 2 つはホストにも公開する
/// (Laperm のサイドバーのフォルダ行へのドロップが同じ規則で画像を選ぶ)。
public enum ImageSourceReader {
    static let pngIdentifier = UTType.png.identifier

    /// `identifier` が画像の型か(`public.file-url` は違う)。
    static func isImageType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .image)
    }

    /// `name` が画像ファイルの名前か(拡張子で決める)。
    static func isImageFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// `types` のうち使う画像の型: PNG があれば PNG(そのまま保存できる)、無ければ最初の画像の型。
    static func preferredImageType(among types: [String]) -> String? {
        let images = types.filter(isImageType)
        return images.first { $0 == pngIdentifier } ?? images.first
    }

    /// 生データを PNG にする(既に PNG ならそのまま)。復号できなければ nil。メインスレッドの外で呼ぶ。
    nonisolated static func pngData(from data: Data, typeIdentifier: String) -> Data? {
        if typeIdentifier == pngIdentifier { return data }
        #if canImport(AppKit)
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return UIImage(data: data)?.pngData()
        #endif
    }

    // MARK: NSItemProvider(iOS のペースト / ドロップ、macOS のサイドバーへのドロップ)

    /// `providers` のどれかが画像(データか画像ファイルの URL)を持つか。
    public static func hasImages(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.registeredTypeIdentifiers.contains(where: isImageType)
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
    }

    /// `providers` から画像を取り出す(項目ごとに 1 枚。画像でない項目は飛ばす)。ファイルの URL は読める間に読む。
    public static func imageSources(from providers: [NSItemProvider]) async -> [ImageAttachmentSource] {
        var sources: [ImageAttachmentSource] = []
        for provider in providers {
            if let source = await imageSource(from: provider) { sources.append(source) }
        }
        return sources
    }

    static func imageSource(from provider: NSItemProvider) async -> ImageAttachmentSource? {
        let types = provider.registeredTypeIdentifiers
        // 画像データ(PNG 優先)。名前が付いていれば利用者のファイル: 形式も名前もそのまま。
        if let type = preferredImageType(among: types), let data = await loadData(from: provider, type: type) {
            if let name = provider.suggestedName, !name.isEmpty {
                let ext = (name as NSString).pathExtension
                let fileName = ext.isEmpty ? (UTType(type)?.preferredFilenameExtension.map { "\(name).\($0)" } ?? name) : name
                return ImageAttachmentSource(data: data, preferredName: fileName, typeIdentifier: type)
            }
            guard let png = await Task.detached(priority: .userInitiated, operation: { pngData(from: data, typeIdentifier: type) }).value
            else { return nil }
            return ImageAttachmentSource(data: png, preferredName: nil, typeIdentifier: pngIdentifier)
        }
        // 画像ファイルの URL
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await loadFileURL(from: provider),
           isImageFileName(url.lastPathComponent)
        {
            return await imageSource(fromFile: url)
        }
        return nil
    }

    /// 画像ファイルを読む(名前と型はファイル名から)。読めなければ nil。
    static func imageSource(fromFile url: URL) async -> ImageAttachmentSource? {
        let name = url.lastPathComponent
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .image) else { return nil }
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }.value
        guard let data else { return nil }
        return ImageAttachmentSource(data: data, preferredName: name, typeIdentifier: type.identifier)
    }

    static func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                switch item {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// `providers` から `handler` の型のデータを集める(項目ごとに最初に合う型を 1 つ)。
    static func droppedItemData(from providers: [NSItemProvider], for handler: DroppedItemHandler) async -> [Data] {
        var result: [Data] = []
        for provider in providers {
            guard let type = handler.typeIdentifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
            if let data = await loadData(from: provider, type: type) { result.append(data) }
        }
        return result
    }

    #if canImport(AppKit)
    // MARK: NSPasteboard(macOS のペースト / エディタへのドロップ)

    /// ペーストボードが画像(データか画像ファイルの URL)を持つか。
    static func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.pasteboardItems?.contains(where: { item in item.types.contains { isImageType($0.rawValue) } }) == true { return true }
        return !imageFileURLs(in: pasteboard).isEmpty
    }

    /// ペーストボードの画像ファイルの URL。
    static func imageFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// ペーストボードから画像を取り出す: 項目ごとの画像データ(PNG 優先、他は PNG に変換、名前なし)、無ければ画像ファイルの URL。
    static func imageSources(from pasteboard: NSPasteboard) async -> [ImageAttachmentSource] {
        var raw: [(Data, String)] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let type = preferredImageType(among: item.types.map(\.rawValue)),
                  let data = item.data(forType: NSPasteboard.PasteboardType(type))
            else { continue }
            raw.append((data, type))
        }
        if !raw.isEmpty {
            let converted = await Task.detached(priority: .userInitiated) {
                raw.compactMap { data, type in pngData(from: data, typeIdentifier: type) }
            }.value
            return converted.map { ImageAttachmentSource(data: $0, preferredName: nil, typeIdentifier: pngIdentifier) }
        }
        var sources: [ImageAttachmentSource] = []
        for url in imageFileURLs(in: pasteboard) {
            if let source = await imageSource(fromFile: url) { sources.append(source) }
        }
        return sources
    }

    /// ペーストボードの項目から `handler` の型のデータを集める(項目ごとに最初に合う型を 1 つ)。
    static func droppedItemData(from pasteboard: NSPasteboard, for handler: DroppedItemHandler) -> [Data] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            handler.typeIdentifiers.lazy.compactMap { item.data(forType: NSPasteboard.PasteboardType($0)) }.first
        }
    }
    #endif
}
