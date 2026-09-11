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

/// リスト項目の直後に空行なしで続く段落(遅延継続行)。swift-markdown / cmark-gfm はこの行の
/// インライン桁をコンテナの内容インデント分("- [ ] " = 6 バイト)過大に報告する
/// (`Text @3:7-3:14 "本文 "` と報告されるが実際は 3 行目の 1 桁目から始まる)。
/// SourceLocationConverter が Text ノードとの照合で補正することを確認する。
@Test func lazyContinuationLineSpansAreAligned() {
    assertAligned("""
    # 見出し
    - [ ] タスク
    本文 **強調** `code`
    [インラインリンク](https://example.com/inline)
    """)
}

/// 引用の遅延継続行(">" なしで続く行)でも同様に補正される
@Test func lazyContinuationAfterBlockquoteIsAligned() {
    assertAligned("""
    > 引用の一行目
    本文 **強調** `code`
    [インラインリンク](https://example.com/inline)
    """)
}

/// 番号付きリスト(内容インデント 3)+ ネストした引用など、補正量が行ごとに異なるケース
@Test func lazyContinuationWithNumberedListIsAligned() {
    let md = """
    1. 項目
    本文 **強調** `code`
       ちゃんとインデントした行 *斜体*
    [インラインリンク](https://example.com/inline)
    """
    assertAligned(md)
    let ns = md as NSString
    let plan = MarkdownParser().highlightPlan(for: md)
    let emphasisRange = ns.range(of: "斜体")
    #expect(plan.spans.contains { $0.kind == .emphasis && NSIntersectionRange($0.range, emphasisRange) == emphasisRange },
            "emphasis span not covering 斜体: \(plan.spans)")
}

/// 正しくインデントされた継続行・エスケープ・実体参照を含む行では補正が誤発動しない
@Test func properlyIndentedContinuationAndEscapesAreNotShifted() {
    let md = """
    - 項目 \\*not\\* **強調** &amp; `code`
      継続行 *斜体* &lt;tag&gt;
    """
    let ns = md as NSString
    let plan = MarkdownParser().highlightPlan(for: md)
    let strongRange = ns.range(of: "強調")
    let codeRange = ns.range(of: "`code`")
    let emphasisRange = ns.range(of: "斜体")
    #expect(plan.spans.contains { $0.kind == .strong && NSIntersectionRange($0.range, strongRange) == strongRange },
            "\(plan.spans)")
    #expect(plan.spans.contains { $0.kind == .inlineCode && NSIntersectionRange($0.range, codeRange) == codeRange },
            "\(plan.spans)")
    #expect(plan.spans.contains { $0.kind == .emphasis && NSIntersectionRange($0.range, emphasisRange) == emphasisRange },
            "\(plan.spans)")
}
