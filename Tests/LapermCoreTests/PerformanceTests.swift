import Foundation
import Markdown
import Testing
@testable import LapermCore

private func makeLargeDocument(lines: Int) -> String {
    var result: [String] = []
    result.reserveCapacity(lines)
    for i in 0..<lines {
        switch i % 6 {
        case 0: result.append("# 見出し \(i)")
        case 1: result.append("Some **bold** and *italic* text with `code` on line \(i).")
        case 2: result.append("- list item \(i) with [link](https://example.com/\(i))")
        case 3: result.append("> 引用テキスト \(i) 🎉")
        case 4: result.append("```\nlet x = \(i)\n```")
        default: result.append("日本語の段落 \(i) plain paragraph.")
        }
    }
    return result.joined(separator: "\n\n")
}

/// 全文パースの回帰ゲート。
///
/// 判定は 2 段構え:
/// 1. **相対比**(主ゲート): `highlightPlan` 全体の時間が、同じ文書を同じ条件で測った
///    `Document(parsing:)`(cmark + swift-markdown の AST 構築)の `ratioBudget` 倍以内。
///    2 つを交互に計測するので、並列テストの CPU 競合や計測スレッドが E コアに置かれる
///    影響は分母と分子で相殺され、「Laperm 側のマッピングが桁で遅くなった」ことだけを見る。
///    実測(2026-09-12、M3)は debug 約 2.0 倍、release 約 2.2 倍。旧 `urlSchemeLength`
///    (全位置で substring + lowercased)では debug 約 3.5 倍、release 約 4.9 倍だった。
/// 2. **絶対時間**(副ゲート): 桁違いの劣化(無限ループに近い退行や二乗劣化)だけを拾う緩い上限。
///    スケジューラの配置で 3 倍以上揺れることが分かっているので、実測に対して余裕を大きく取る。
///
/// 文書はネイティブ String と、`NSTextStorage.string` と同じ非連続(foreign)表現の両方で測る。
/// 実運用は後者を通るため、ネイティブだけ測ると表現依存の劣化(UTF-8 インデックス操作の
/// 二乗化)を見逃す。
@Test func fullParseOf10kLinesStaysWithinBudget() {
    let native = makeLargeDocument(lines: 10_000)
    let foreign = makeForeignString(native)
    let parser = MarkdownParser()
    let clock = ContinuousClock()

    let ratioBudget = 3.0
    #if DEBUG
    let baseBudget: Duration = .seconds(1)
    #else
    // release は CI では回していない。手動で `swift test -c release -Xswiftc -enable-testing`。
    // 実測は 10k 行で約 90ms(2026-09-12、M3)。
    let baseBudget: Duration = .milliseconds(200)
    #endif
    // iOS シミュレータは実機・macOS ネイティブより数倍遅く、同一マシンでも 2 倍以上ばらつく。
    #if targetEnvironment(simulator)
    let absoluteBudget = baseBudget * 10
    #else
    let absoluteBudget = baseBudget
    #endif

    for (name, text) in [("native", native), ("foreign", foreign)] {
        _ = parser.highlightPlan(for: text)  // ウォームアップ
        // 交互に計測し、3 回の最小値を採る(単発計測はスケジューラノイズで揺れる)。
        var parseOnlySamples: [Duration] = []
        var totalSamples: [Duration] = []
        for _ in 0..<3 {
            parseOnlySamples.append(clock.measure { _ = Document(parsing: text) })
            totalSamples.append(clock.measure { _ = parser.highlightPlan(for: text) })
        }
        let parseOnly = parseOnlySamples.min()!
        let total = totalSamples.min()!
        let ratio = total / parseOnly
        #expect(ratio < ratioBudget,
                "[\(name)] 全文パース \(total) が cmark パース \(parseOnly) の \(ratio) 倍(閾値 \(ratioBudget) 倍)")
        #expect(total < absoluteBudget,
                "[\(name)] 全文パースが \(total) かかった(絶対閾値 \(absoluteBudget))")
    }
}

@Test func diffOfSingleEditIsSmall() {
    let text = makeLargeDocument(lines: 10_000)
    let parser = MarkdownParser()
    let before = parser.highlightPlan(for: text)

    // 文書中央の 1 段落だけを変更したのと等価な編集(1 文字挿入)
    let insertAt = (text as NSString).length / 2
    let edited = (text as NSString).replacingCharacters(
        in: NSRange(location: insertAt, length: 0), with: "x")
    let after = parser.highlightPlan(for: edited)

    let shifted = before.shifted(
        byEditAt: NSRange(location: insertAt, length: 1), changeInLength: 1)
    let changes = HighlightDiff.compute(
        old: shifted, new: after,
        alwaysInvalidating: [NSRange(location: insertAt, length: 1)])

    // 差分適用対象が全スパンの 1% 未満であること(=差分化が機能している)
    #expect(changes.spansToApply.count < after.spans.count / 100,
            "再適用スパン \(changes.spansToApply.count) / 全 \(after.spans.count)")
}

// MARK: - 実運用経路の文字列表現

/// `NSTextStorage.string` が返す Swift String は、非 ASCII を含むと NSString を包んだ
/// 非連続(foreign)表現になり、UTF-8 インデックス操作のコストがネイティブ String と桁で違う。
/// Foundation だけで同じ表現を作るには `NSMutableAttributedString.mutableString` を
/// ブリッジする(`NSMutableString(string:)` は ASCII 連続バッファの高速経路に乗ってしまう)。
private func makeForeignString(_ text: String) -> String {
    let foreign = NSMutableAttributedString(string: text).mutableString as String
    precondition(!foreign.isContiguousUTF8, "テストの前提: 非連続表現の文字列を再現できていない")
    return foreign
}

/// 1 行に多数のインライン要素を並べた文書(非 ASCII を含めて foreign 表現を強制する)。
/// 旧実装では foreign 文字列に対して行あたり「インラインノード数 × 行長」のコストになっていた
/// (2,000 語で約 0.5〜1.7 秒、ネイティブは 0.03 秒)。
private func makeInlineHeavyLine(words: Int) -> String {
    "あ " + (0..<words).map { "*e\($0)*" }.joined(separator: " ")
}

@Test func foreignStringProducesSamePlanAsNative() {
    let native = makeLargeDocument(lines: 2_000)
    let foreign = makeForeignString(native)
    let parser = MarkdownParser()
    #expect(parser.highlightPlan(for: foreign) == parser.highlightPlan(for: native))
}

@Test func foreignStringParseIsNotQuadraticInLineLength() {
    let native = makeInlineHeavyLine(words: 2_000)
    let foreign = makeForeignString(native)
    let parser = MarkdownParser()
    _ = parser.highlightPlan(for: native)
    let clock = ContinuousClock()
    let nativeTime = (0..<3).map { _ in clock.measure { _ = parser.highlightPlan(for: native) } }.min()!
    let foreignTime = (0..<3).map { _ in clock.measure { _ = parser.highlightPlan(for: foreign) } }.min()!
    // foreign は「ネイティブへの 1 回のコピー + 同じ処理」なので数倍以内に収まる。
    // 二乗劣化していると 2,000 語で 100 倍超になる。
    #expect(foreignTime < nativeTime * 4 + .milliseconds(20),
            "foreign \(foreignTime) vs native \(nativeTime)")
}
