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
    let budget: Duration = .milliseconds(400)
    #else
    let budget: Duration = .milliseconds(100)
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
