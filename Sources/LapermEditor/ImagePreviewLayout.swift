import Foundation
import LapermCore

/// 予約領域(paragraphSpacing)内に画像を積むレイアウト計算。純粋関数。
enum ImagePreviewLayout {
    struct Item: Equatable {
        var reference: ImageReference
        var frame: CGRect
    }

    /// テキスト行の下端(`textLinesBottom`、テキストコンテナ座標)を予約領域の
    /// 先頭として、段落内の画像をソース順で縦に積む。各画像はスロット(高さ + padding)
    /// の中央に置く。
    ///
    /// 起点を `fragmentFrame.maxY - totalHeight` ではなくテキスト行の下端にするのは、
    /// TextKit2 が文書末尾の段落について trailing paragraphSpacing を
    /// layoutFragmentFrame に含めないことがあり、その場合 maxY 起点だと予約領域が
    /// テキストの上に食い込んでしまうため。テキスト行下端を起点にすれば、
    /// frame に spacing が含まれるか否かに関わらず常にテキストの下へ積める。
    static func itemFrames(
        references: [ImageReference],
        sizes: [CGSize],
        fragmentFrame: CGRect,
        textLinesBottom: CGFloat,
        leadingInset: CGFloat,
        padding: CGFloat
    ) -> [Item] {
        var y = fragmentFrame.minY + textLinesBottom
        var items: [Item] = []
        for (reference, size) in zip(references, sizes) {
            items.append(Item(
                reference: reference,
                frame: CGRect(
                    x: fragmentFrame.minX + leadingInset,
                    y: y + padding / 2,
                    width: size.width,
                    height: size.height)))
            y += size.height + padding
        }
        return items
    }
}

/// オーバーレイに渡す 1 画像ぶんの表示指示(frame は textView 座標)。両 OS 共通。
struct ImagePreviewOverlayEntry {
    var reference: ImageReference
    var frame: CGRect
    var state: ImagePreviewController.State
}
