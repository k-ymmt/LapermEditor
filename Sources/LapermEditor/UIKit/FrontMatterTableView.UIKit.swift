#if canImport(UIKit)
import UIKit

/// Live Preview の Front Matter の表を描く非ヒットテストのオーバーレイ(UIKit)。タップはテキストビューの
/// タップジェスチャが拾ってブロックを展開する。
final class FrontMatterTableView: UIView {
    private(set) var entry: FrontMatterTableEntry? {
        didSet {
            isHidden = entry == nil
            if let entry {
                if frame != entry.frame { frame = entry.frame }
                if entry != oldValue { setNeedsDisplay() }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FrontMatterTableView does not support NSCoder")
    }

    func update(entry: FrontMatterTableEntry?) { self.entry = entry }

    override func draw(_ rect: CGRect) {
        guard let entry, let context = UIGraphicsGetCurrentContext() else { return }
        FrontMatterTableRenderer.draw(entry.layout, appearance: entry.appearance, in: context)
    }
}
#endif
