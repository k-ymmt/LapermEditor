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

// MARK: - 桁補正の決定性(Text ノード照合ヒューリスティックの誤判定に対する回帰テスト)

private func spanRange(_ md: String, _ kind: SyntaxKind, covering fragment: String) -> NSRange? {
    let target = (md as NSString).range(of: fragment)
    return MarkdownParser().highlightPlan(for: md).spans
        .first { $0.kind == kind && NSIntersectionRange($0.range, target) == target }?.range
}

/// 先頭がエスケープの通常行(Text "# Title " が原文の 1 バイト後ろに出現する)で補正が誤発動し、
/// 行末のスパンが消えていた
@Test func leadingEscapeOnNormalLineIsNotShifted() {
    #expect(spanRange("\\# Title `code`", .inlineCode, covering: "`code`") == NSRange(location: 9, length: 6))
    #expect(spanRange("- \\* `code`", .inlineCode, covering: "`code`") == NSRange(location: 5, length: 6))
    #expect(spanRange("\\#hashtag `tag`", .inlineCode, covering: "`tag`") == NSRange(location: 10, length: 5))
}

/// 遅延継続行に原文と一致する Text ノードがなくても(コード・エスケープ・実体参照のみ)補正される
@Test func lazyLineWithoutVerbatimTextIsCorrected() {
    #expect(spanRange("- item\n`only code`", .inlineCode, covering: "`only code`") == NSRange(location: 7, length: 11))
    #expect(spanRange("- item\n\\*a\\* `code` &amp;", .inlineCode, covering: "`code`") == NSRange(location: 13, length: 6))
    #expect(spanRange("- item\n&amp; **bold**", .strong, covering: "**bold**") == NSRange(location: 13, length: 8))
}

/// 空白 1 文字の Text ノードが偶然一致しても行全体が「補正不要」扱いにならない
@Test func coincidentalTextMatchDoesNotSuppressCorrection() {
    let md = "- [ ] task\n`code` **b** x"
    #expect(spanRange(md, .inlineCode, covering: "`code`") == NSRange(location: 11, length: 6))
    #expect(spanRange(md, .strong, covering: "**b**") == NSRange(location: 18, length: 5))
    #expect(spanRange("- x\na*a* text", .emphasis, covering: "*a*") == NSRange(location: 5, length: 3))
    #expect(spanRange("1. x\n**ab** ab", .strong, covering: "**ab**") == NSRange(location: 5, length: 6))
}

/// 引用の遅延継続行で 4 桁以上インデントされた ">" は内容(接頭辞ではない)
@Test func deeplyIndentedQuoteMarkerOnLazyLineIsContent() {
    #expect(spanRange("> a\n    > b **c**", .strong, covering: "**c**") == NSRange(location: 12, length: 5))
}

/// ネストしたコンテナ(リスト > リスト > 引用)の通常継続行と、タブを含む接頭辞
@Test func nestedContainersAndTabPrefixesAreAligned() {
    #expect(spanRange("- - > a\n    > b **c**", .strong, covering: "**c**") == NSRange(location: 16, length: 5))
    #expect(spanRange(">\tfoo **bar**\n>\tbaz **qux**", .strong, covering: "**qux**") == NSRange(location: 20, length: 7))
    #expect(spanRange("-\titem\nlazy **b**", .strong, covering: "**b**") == NSRange(location: 12, length: 5))
    #expect(spanRange("100. item\n     cont **b**\nlazy **c**", .strong, covering: "**c**") == NSRange(location: 31, length: 5))
}

/// 長い遅延継続行でもコストが行長の二乗にならない(旧実装は 80KB で 5 秒超)
@Test func longLazyLineIsCorrectedInLinearTime() {
    let line = String(repeating: "a*b*", count: 20_000)
    let md = "- x\n" + line
    let clock = ContinuousClock()
    var plan: HighlightPlan?
    let elapsed = clock.measure { plan = MarkdownParser().highlightPlan(for: md) }
    #expect(plan!.spans.contains { $0.kind == .emphasis && $0.range == NSRange(location: 5, length: 3) })
    // 実測は macOS debug 約 0.4 秒。iOS シミュレータは約 4 倍遅く(単独で 1.4 秒)、
    // 並列実行される性能テストとの競合で 2 秒を超えることがあるため、二乗劣化
    // (数十秒)だけを検知できる上限に緩める。
    #if targetEnvironment(simulator)
    let budget: Duration = .seconds(8)
    #else
    let budget: Duration = .seconds(2)
    #endif
    #expect(elapsed < budget, "\(elapsed)")
}
