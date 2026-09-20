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
@MainActor
final class EditorContentStorageDelegate: NSObject {
    let foldingController: FoldingController
    let fragmentProvider: BlockFragmentProvider

    init(foldingController: FoldingController, fragmentProvider: BlockFragmentProvider) {
        self.foldingController = foldingController
        self.fragmentProvider = fragmentProvider
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
        fragmentProvider.textParagraph(with: range, in: textContentStorage)
    }
}
