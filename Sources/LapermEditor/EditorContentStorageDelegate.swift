#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// エディタが NSTextContentStorage の delegate として使う複合オブジェクト。
/// - 折畳: 折畳中の本体段落を列挙から除外する(`FoldingController`)。
/// - コードブロック: 先頭 / 末尾段落に上下余白の段落スタイルを付けた表示用段落を返す
///   (`BlockFragmentProvider`)。textStorage は変更しないので、タイピング属性として
///   次の段落へ余白が引き継がれることがない。
/// - Live Preview: フォーカスの無い段落の Syntax Marker を幅ゼロで隠した表示用段落を返す
///   (`LivePreviewConcealer`)。コードブロックの表示用段落の上に重ねる。
/// - Front Matter: 表に折りたたまれている間、開きの `---` 以外の段落を列挙から除外し、開きの段落には
///   文字を隠して表の高さを予約した表示用段落を返す(`FrontMatterController`、ADR 0016)。
/// - テーブル: 同じく、折りたたまれている間はヘッダー行以外の段落を列挙から除外し、ヘッダー行の段落に
///   表の高さを予約する(`TablePreviewController`、ADR 0019)。
@MainActor
final class EditorContentStorageDelegate: NSObject {
    let foldingController: FoldingController
    let fragmentProvider: BlockFragmentProvider
    let livePreview: LivePreviewConcealer
    /// nil なら Front Matter の折りたたみ無し(単体テストの継ぎ目)。
    let frontMatter: FrontMatterController?
    /// nil ならテーブルの折りたたみ無し(単体テストの継ぎ目)。
    let tables: TablePreviewController?

    init(
        foldingController: FoldingController, fragmentProvider: BlockFragmentProvider,
        livePreview: LivePreviewConcealer, frontMatter: FrontMatterController? = nil,
        tables: TablePreviewController? = nil
    ) {
        self.foldingController = foldingController
        self.fragmentProvider = fragmentProvider
        self.livePreview = livePreview
        self.frontMatter = frontMatter
        self.tables = tables
    }
}

extension EditorContentStorageDelegate: NSTextContentStorageDelegate {
    func textContentManager(
        _ textContentManager: NSTextContentManager,
        shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions
    ) -> Bool {
        // 折りたたまれた Front Matter の段落(開きの `---` 以外)とテーブルの段落(ヘッダー行以外)は列挙しない
        if frontMatter?.isCollapsed == true || tables?.presented.isEmpty == false,
           let location = textElement.elementRange?.location {
            let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: location)
            if let frontMatter, frontMatter.isCollapsed, !frontMatter.shouldEnumerate(paragraphStartingAt: offset) { return false }
            if let tables, !tables.shouldEnumerate(paragraphStartingAt: offset) { return false }
        }
        return foldingController.textContentManager(
            textContentManager, shouldEnumerate: textElement, options: options)
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        // 折りたたまれた Front Matter の開きの段落 / テーブルのヘッダー行(文字を隠し、表の高さを予約)は他の仕組みより優先
        if let collapsed = frontMatter?.textParagraph(with: range, in: textContentStorage) { return collapsed }
        if let collapsed = tables?.textParagraph(with: range, in: textContentStorage) { return collapsed }
        let base = fragmentProvider.textParagraph(with: range, in: textContentStorage)
        // 展開中のテーブルのブロックは Source と同じ見た目(行単位の Syntax Marker 隠し無し。ADR 0019)
        if tables?.isExempt(paragraph: range) == true { return base }
        return livePreview.textParagraph(with: range, base: base, in: textContentStorage)
    }
}
