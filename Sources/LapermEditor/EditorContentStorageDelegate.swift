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
@MainActor
final class EditorContentStorageDelegate: NSObject {
    let foldingController: FoldingController
    let fragmentProvider: BlockFragmentProvider
    let livePreview: LivePreviewConcealer

    init(foldingController: FoldingController, fragmentProvider: BlockFragmentProvider, livePreview: LivePreviewConcealer) {
        self.foldingController = foldingController
        self.fragmentProvider = fragmentProvider
        self.livePreview = livePreview
    }
}

extension EditorContentStorageDelegate: NSTextContentStorageDelegate {
    func textContentManager(
        _ textContentManager: NSTextContentManager,
        shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions
    ) -> Bool {
        foldingController.textContentManager(
            textContentManager, shouldEnumerate: textElement, options: options)
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        let base = fragmentProvider.textParagraph(with: range, in: textContentStorage)
        return livePreview.textParagraph(with: range, base: base, in: textContentStorage)
    }
}
