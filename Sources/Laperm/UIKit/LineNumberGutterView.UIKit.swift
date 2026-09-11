#if canImport(UIKit)
import UIKit

/// UITextView の左端に重ねて行番号と折畳シェブロンを描画するガター(UIKit)。
/// UIKit には NSRulerView 相当が無いため、テキストビューのサブビューとして可視領域に
/// ピン留めし(スクロールに追従して frame を動かす)、行情報は MarkdownTextView の
/// viewport レイアウトパスから供給される。テキストは `textContainerInset.left` で右へ逃がす。
@MainActor
final class LineNumberGutterView: UIView {
    typealias FoldMarker = GutterFoldMarker
    typealias Line = GutterLine

    static let width: CGFloat = 44

    var lines: [Line] = [] {
        didSet { if lines != oldValue { setNeedsDisplay() } }
    }
    /// 可視領域の上端(テキストビューのコンテンツ座標)。行 y からこれを引いてガター座標にする。
    var contentOffsetY: CGFloat = 0 {
        didSet { if contentOffsetY != oldValue { setNeedsDisplay() } }
    }
    var numberFont: UIFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var numberColor: UIColor = .tertiaryLabel
    var chevronColor: UIColor = .secondaryLabel
    /// シェブロンのタップで呼ばれる(引数は headingLocation)
    var onToggleFold: ((Int) -> Void)?

    /// シェブロン列の幅(左端からここまでがタップ判定域)
    private let chevronColumnWidth: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LineNumberGutterView does not support NSCoder")
    }

    /// point(ガター座標)がシェブロンに当たっていればその headingLocation を返す
    func foldMarkerHeadingLocation(atPoint point: CGPoint) -> Int? {
        guard point.x <= chevronColumnWidth else { return nil }
        // 見出し行はガター数字フォントより高くレイアウトされるため、固定行高では
        // H1/H2 行の下半分がタップ不能になる。実フラグメント高で判定し、
        // フィクスチャ等で高さが未指定(<= 0)の場合のみフォント由来の値にフォールバックする。
        let fallbackLineHeight = numberFont.ascender - numberFont.descender + 6
        for line in lines {
            guard let marker = line.foldMarker else { continue }
            let lineHeight = line.heightInTextView > 0 ? line.heightInTextView : fallbackLineHeight
            let y = line.yInTextView - contentOffsetY
            if point.y >= y, point.y < y + lineHeight {
                return marker.headingLocation
            }
        }
        return nil
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        if let headingLocation = foldMarkerHeadingLocation(atPoint: point) {
            onToggleFold?(headingLocation)
        }
    }

    override func draw(_ rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor,
        ]
        let chevronAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: chevronColor,
        ]
        for line in lines {
            let y = line.yInTextView - contentOffsetY
            guard y + max(line.heightInTextView, 1) >= rect.minY, y <= rect.maxY else { continue }
            let label = NSAttributedString(string: "\(line.number)", attributes: attributes)
            let size = label.size()
            label.draw(at: CGPoint(x: bounds.width - size.width - 6, y: y))
            if let marker = line.foldMarker {
                let chevron = NSAttributedString(
                    string: marker.isFolded ? "▶" : "▼", attributes: chevronAttributes)
                chevron.draw(at: CGPoint(x: 4, y: y + 1))
            }
        }
    }
}
#endif
