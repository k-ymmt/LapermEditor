import AppKit

/// スクロールビューの垂直ルーラーとして行番号と折畳シェブロンを描画する。
/// 行情報は MarkdownTextView の viewport レイアウトパスから供給される。
@MainActor
final class LineNumberGutterView: NSRulerView {
    /// 見出し行に表示する折畳インジケータ
    struct FoldMarker: Equatable {
        var headingLocation: Int
        var isFolded: Bool
    }

    struct Line: Equatable {
        var number: Int
        /// テキストビュー座標系でのフラグメント上端 y
        var yInTextView: CGFloat
        /// フラグメントの高さ(ヒット判定の行窓に使う)
        var heightInTextView: CGFloat = 0
        var foldMarker: FoldMarker? = nil
    }

    var lines: [Line] = [] {
        didSet { if lines != oldValue { needsDisplay = true } }
    }
    var numberFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var numberColor: NSColor = .tertiaryLabelColor
    var chevronColor: NSColor = .secondaryLabelColor
    /// シェブロンのクリックで呼ばれる(引数は headingLocation)
    var onToggleFold: ((Int) -> Void)?

    /// シェブロン列の幅(左端からここまでがクリック判定域)
    private let chevronColumnWidth: CGFloat = 16

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 44
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberGutterView does not support NSCoder")
    }

    /// point(ガター座標)がシェブロンに当たっていればその headingLocation を返す
    func foldMarkerHeadingLocation(atPoint point: NSPoint) -> Int? {
        guard point.x <= chevronColumnWidth, let textView = clientView else { return nil }
        // 見出し行はガター数字フォントより高くレイアウトされるため、固定行高では
        // H1/H2 行の下半分がクリック不能になる。実フラグメント高で判定し、
        // フィクスチャ等で高さが未指定(<= 0)の場合のみフォント由来の値にフォールバックする。
        let fallbackLineHeight = numberFont.ascender - numberFont.descender + 6
        for line in lines {
            guard let marker = line.foldMarker else { continue }
            let lineHeight = line.heightInTextView > 0 ? line.heightInTextView : fallbackLineHeight
            let y = convert(NSPoint(x: 0, y: line.yInTextView), from: textView).y
            if point.y >= y, point.y < y + lineHeight {
                return marker.headingLocation
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let headingLocation = foldMarkerHeadingLocation(atPoint: point) {
            onToggleFold?(headingLocation)
            return
        }
        super.mouseDown(with: event)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor,
        ]
        let chevronAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: chevronColor,
        ]
        for line in lines {
            let y = convert(NSPoint(x: 0, y: line.yInTextView), from: textView).y
            let label = NSAttributedString(string: "\(line.number)", attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y))
            if let marker = line.foldMarker {
                let chevron = NSAttributedString(
                    string: marker.isFolded ? "▶" : "▼", attributes: chevronAttributes)
                chevron.draw(at: NSPoint(x: 4, y: y + 1))
            }
        }
    }
}
