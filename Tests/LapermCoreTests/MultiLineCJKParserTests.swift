import Foundation
import Markdown
import Testing
@testable import LapermCore

private func assertAligned(_ md: String) {
    let ns = md as NSString
    let plan = MarkdownParser().highlightPlan(for: md)
    let strongRange = ns.range(of: "強調")
    let codeRange = ns.range(of: "`code`")
    let linkRange = ns.range(of: "[インラインリンク](https://example.com/inline)")
    #expect(plan.spans.contains { $0.kind == .strong && NSIntersectionRange($0.range, strongRange) == strongRange },
            "strong span not covering 強調 (\(strongRange)): \(plan.spans)")
    #expect(plan.spans.contains { $0.kind == .inlineCode && NSIntersectionRange($0.range, codeRange) == codeRange },
            "inlineCode span not covering `code` (\(codeRange)): \(plan.spans)")
    #expect(plan.spans.contains { $0.kind == .link && NSIntersectionRange($0.range, linkRange) == linkRange },
            "link span not covering link (\(linkRange)): \(plan.spans)")
    #expect(plan.links.first?.range == linkRange, "\(plan.links)")
}

/// 複数行 + CJK 文書で、3 行目以降のスパン位置(UTF-16)がずれないこと。
@Test func multiLineCJKDocumentSpansAreAligned() {
    assertAligned("""
    # 見出し
    - [ ] タスク

    本文 **強調** `code`
    [インラインリンク](https://example.com/inline)
    > 引用

    ## 次の見出し
    末尾
    """)
}

/// 既知の問題: リスト項目の直後に空行なしで続く段落(遅延継続行)では、swift-markdown /
/// cmark-gfm が報告する列がコンテナの内容インデント分("- [ ] " = 6 バイト)ずれるため、
/// インラインスパンが誤った文字に載る(macOS / iOS 共通)。
/// 例: `Text @3:7-3:14 "本文 "` と報告されるが実際は 3 行目の 1 桁目から始まる。
@Test(.disabled("swift-markdown の遅延継続行の列ずれ(未対応)。修正時に有効化する"))
func lazyContinuationLineSpansAreAligned() {
    assertAligned("""
    # 見出し
    - [ ] タスク
    本文 **強調** `code`
    [インラインリンク](https://example.com/inline)
    """)
}
