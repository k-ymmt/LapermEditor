import Foundation
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

@Test func fullParseOf10kLinesStaysWithinBudget() {
    let text = makeLargeDocument(lines: 10_000)
    let parser = MarkdownParser()
    _ = parser.highlightPlan(for: text)  // ウォームアップ

    let clock = ContinuousClock()
    // テストは並列実行されるため単発計測はスケジューラノイズで揺れる。
    // 3 回計測の最小値なら真のコストに近く、リグレッション検知の意図を保てる。
    let elapsed = (0..<3).map { _ in
        clock.measure { _ = parser.highlightPlan(for: text) }
    }.min()!
    // リグレッション閾値。実機目標は 16ms(spec)だが、この回帰テストの狙いは
    // 「パースが桁で遅くなったら気付く」こと。debug ビルドは Swift の
    // 最適化なしで 2〜3 倍遅いため閾値を分ける。
    #if DEBUG
    let baseBudget: Duration = .milliseconds(400)
    #else
    let baseBudget: Duration = .milliseconds(100)
    #endif
    // iOS シミュレータは実機・macOS ネイティブより数倍遅く、同一マシンでも実測が
    // 1.1〜2.3s / 10k 行と 2 倍以上ばらつく(×4 = 1.6s では 4 回に 1 回落ちた)。
    // 回帰の実質的なゲートは macOS の閾値に任せ、シミュレータでは桁違いの劣化だけを検知する。
    #if targetEnvironment(simulator)
    let budget = baseBudget * 10
    #else
    let budget = baseBudget
    #endif
    #expect(elapsed < budget, "全文パースが \(elapsed) かかった(閾値 \(budget))")
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
