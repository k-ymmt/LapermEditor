import AppKit

/// スクロールビューの垂直ルーラーとして行番号を描画する。
/// 行情報は MarkdownTextView の viewport レイアウトパスから供給される。
@MainActor
final class LineNumberGutterView: NSRulerView {
    struct Line: Equatable {
        var number: Int
        /// テキストビュー座標系でのフラグメント上端 y
        var yInTextView: CGFloat
    }

    var lines: [Line] = [] {
        didSet { if lines != oldValue { needsDisplay = true } }
    }
    var numberFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var numberColor: NSColor = .tertiaryLabelColor

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 44
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberGutterView does not support NSCoder")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor,
        ]
        for line in lines {
            let label = NSAttributedString(string: "\(line.number)", attributes: attributes)
            let size = label.size()
            let y = convert(NSPoint(x: 0, y: line.yInTextView), from: textView).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y))
        }
    }
}
