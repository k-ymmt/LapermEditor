# リンク操作(Cmd+クリック・ベア URL 検出・ペーストリンク化)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `MarkdownTextView` に Cmd+クリックでリンクを開く・ベア URL 検出・URL ペーストのリンク化を追加する。

**Architecture:** 既存の「Core が判断し UI が適用する」2 層構造を踏襲。Core は `HighlightMapper` で `LinkReference` を収集して `HighlightPlan.links` に載せ、ペースト変換は `EditingAssistant` の純粋関数で判断する。UI は `MarkdownTextView` が Cmd+クリック / ホバー / ペーストを検出して Core の結果を適用する。

**Tech Stack:** Swift 6 / macOS 27+ / TextKit2 / swift-markdown / Swift Testing

**Spec:** `docs/superpowers/specs/2026-07-17-link-interaction-design.md`

## Global Constraints

- 対象プラットフォームは macOS 27+、Swift 6。外部依存は swift-markdown のみ
- LapermCore は AppKit を import しない(Foundation のみ)
- `MarkdownTextView` では `layoutManager` プロパティに絶対にアクセスしない(TextKit1 フォールバックが起きる)
- テストは常に全体実行: `swift test`(この環境では `--filter` が効かない。全体でも約 0.5 秒)
- コミットは main へ直接。メッセージ末尾に以下を付ける:
  ```
  Task context: リンク操作 (docs/superpowers/specs/2026-07-17-link-interaction-design.md)

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01KKBTtzv3UxhX8vTPruvGJc
  ```
- swift-markdown は autolink 拡張を有効化していない(table / strikethrough / tasklist のみ)。ベア URL は Link ノードにならないため Core で自前検出する
- 既存コードのコメント言語(日本語)・命名・スタイルに合わせる

---

### Task 1: LinkReference と HighlightPlan.links

**Files:**
- Create: `Sources/LapermCore/LinkReference.swift`
- Modify: `Sources/LapermCore/HighlightPlan.swift`
- Test: `Tests/LapermCoreTests/HighlightPlanTests.swift`(追記)

**Interfaces:**
- Consumes: なし
- Produces: `LinkReference(text: String, destination: String, range: NSRange)`(Hashable, Sendable)/ `HighlightPlan.links: [LinkReference]` / `HighlightPlan.init(spans:images:links:)`(links デフォルト `[]`)/ `shifted(byEditAt:changeInLength:)` が links も平行移動・交差破棄する

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/HighlightPlanTests.swift` に追記:

```swift
@Test func shiftMovesLinksAfterEdit() {
    let link = LinkReference(
        text: "a", destination: "https://example.com",
        range: NSRange(location: 10, length: 5))
    let plan = HighlightPlan(links: [link])
    // 位置 0 に 3 文字挿入(editedRange は編集後座標)
    let shifted = plan.shifted(byEditAt: NSRange(location: 0, length: 3), changeInLength: 3)
    #expect(shifted.links == [LinkReference(
        text: "a", destination: "https://example.com",
        range: NSRange(location: 13, length: 5))])
}

@Test func shiftDropsLinksIntersectingEdit() {
    let link = LinkReference(
        text: "a", destination: "https://example.com",
        range: NSRange(location: 10, length: 5))
    let plan = HighlightPlan(links: [link])
    let shifted = plan.shifted(byEditAt: NSRange(location: 12, length: 1), changeInLength: 1)
    #expect(shifted.links.isEmpty)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー(`LinkReference` 未定義)

- [ ] **Step 3: 実装**

`Sources/LapermCore/LinkReference.swift` を新規作成:

```swift
import Foundation

/// リンク 1 箇所ぶんの参照情報。UI 層のクリック処理が消費する。
public struct LinkReference: Hashable, Sendable {
    /// リンクテキスト(装飾を除いたプレーンテキスト。ベア URL では URL 自身)
    public var text: String
    /// 記法に書かれた URL 文字列(未解決)
    public var destination: String
    /// 記法全体の UTF-16 レンジ(ベア URL では URL 自身のレンジ)
    public var range: NSRange

    public init(text: String, destination: String, range: NSRange) {
        self.text = text
        self.destination = destination
        self.range = range
    }
}
```

`Sources/LapermCore/HighlightPlan.swift` を修正:

1. プロパティと init に links を追加:

```swift
    /// リンクの出現一覧(クリック処理用)
    public var links: [LinkReference]

    public init(
        spans: [HighlightSpan] = [], images: [ImageReference] = [],
        links: [LinkReference] = []
    ) {
        self.spans = spans
        self.images = images
        self.links = links
    }
```

2. `shifted(byEditAt:changeInLength:)` の `return HighlightPlan(...)` の直前に links の処理を追加し、戻り値に渡す:

```swift
        var resultLinks: [LinkReference] = []
        resultLinks.reserveCapacity(links.count)
        for link in links {
            guard let range = Self.shift(link.range, preEditRange: preEditRange, delta: delta)
            else { continue }
            var moved = link
            moved.range = range
            resultLinks.append(moved)
        }
        return HighlightPlan(spans: resultSpans, images: resultImages, links: resultLinks)
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/LinkReference.swift Sources/LapermCore/HighlightPlan.swift Tests/LapermCoreTests/HighlightPlanTests.swift
git commit -m "feat(core): add LinkReference and HighlightPlan.links"
```

(メッセージ末尾に Global Constraints のトレーラを付ける。以降のコミットも同様)

---

### Task 2: HighlightMapper のリンク収集(記法リンク)

**Files:**
- Modify: `Sources/LapermCore/HighlightMapper.swift`
- Test: Create `Tests/LapermCoreTests/LinkDetectionTests.swift`

**Interfaces:**
- Consumes: Task 1 の `LinkReference` / `HighlightPlan.links`
- Produces: `MarkdownParser().highlightPlan(for:).links` にインラインリンク・参照リンク・角括弧 autolink の `LinkReference` が入る

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/LinkDetectionTests.swift` を新規作成:

```swift
import Foundation
import Testing
@testable import LapermCore

private func links(in markdown: String) -> [LinkReference] {
    MarkdownParser().highlightPlan(for: markdown).links
}

@Test func collectsInlineLinkDestination() {
    let md = "See [site](https://example.com/a)."
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/a")
    #expect(result[0].text == "site")
    #expect((md as NSString).substring(with: result[0].range)
        == "[site](https://example.com/a)")
}

@Test func collectsReferenceLinkDestination() {
    let md = "See [site][ref].\n\n[ref]: https://example.com/r"
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/r")
    #expect((md as NSString).substring(with: result[0].range) == "[site][ref]")
}

@Test func collectsAngleAutolink() {
    let md = "Go <https://example.com> now."
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com")
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: `collectsInlineLinkDestination` 等が FAIL(`result.count == 0`)

- [ ] **Step 3: 実装**

`Sources/LapermCore/HighlightMapper.swift` を修正:

1. `plan(for:in:)` の戻り値に links を追加:

```swift
        return HighlightPlan(
            spans: visitor.blockSpans + visitor.inlineSpans + visitor.markerSpans,
            images: visitor.imageReferences,
            links: visitor.linkReferences
        )
```

2. Visitor にプロパティを追加(`imageReferences` の隣):

```swift
        var linkReferences: [LinkReference] = []
```

3. `visitLink` を差し替え:

```swift
        mutating func visitLink(_ link: Link) {
            if let range = nsRange(of: link), range.length > 0 {
                inlineSpans.append(HighlightSpan(range: range, kind: .link))
                linkReferences.append(LinkReference(
                    text: plainText(of: link),
                    destination: link.destination ?? "",
                    range: range))
            }
            descendInto(link)
        }
```

4. 既存の `plainAltText(of image:)` を汎用化する。`plainAltText` を削除し、以下に置き換えて `visitImage` の呼び出しを `plainText(of: image)` へ変更:

```swift
        /// 子孫の Text ノードを連結したプレーンテキスト(強調などの装飾を剥がす)。
        private func plainText(of markup: Markup) -> String {
            var result = ""
            func collect(_ markup: Markup) {
                if let textNode = markup as? Markdown.Text { result += textNode.string }
                for child in markup.children { collect(child) }
            }
            collect(markup)
            return result
        }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/HighlightMapper.swift Tests/LapermCoreTests/LinkDetectionTests.swift
git commit -m "feat(core): collect LinkReference for syntax links in HighlightMapper"
```

---

### Task 3: ベア URL の検出

**Files:**
- Modify: `Sources/LapermCore/HighlightMapper.swift`
- Test: `Tests/LapermCoreTests/LinkDetectionTests.swift`(追記)

**Interfaces:**
- Consumes: Task 2 の Visitor 構造
- Produces: ベア URL(`http://` / `https://`)が `.link` スパン + `LinkReference` になる。`text == destination == URL 文字列`

検出仕様(スペック準拠):

- URL 文字は ASCII 可視文字(0x21–0x7E)のみ。空白・制御文字・`<`・非 ASCII(全角文字等)で終端する
- 末尾の `.` `,` `;` `:` `!` `?` `'` `"` はトリムする。`)` は URL 内の `(` `)` の数を比べ、閉じ超過分のみトリムする(GFM の括弧バランス規則)
- URL 直前の文字が ASCII 英数字なら検出しない(`xhttps://…` 誤検出防止)
- スキームだけ(`https://` のみ)は検出しない
- コードスパン / コードブロック内は `visitText` が呼ばれないため自然に除外。リンク・画像の内側は深度フラグで除外する

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/LinkDetectionTests.swift` に追記:

```swift
@Test func detectsBareURL() {
    let md = "See https://example.com/path now"
    let result = links(in: md)
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/path")
    #expect((md as NSString).substring(with: result[0].range) == "https://example.com/path")
}

@Test func bareURLGetsLinkSpan() {
    let md = "See https://example.com now"
    let plan = MarkdownParser().highlightPlan(for: md)
    let expected = ((md as NSString).range(of: "https://example.com"))
    #expect(plan.spans.contains(HighlightSpan(range: expected, kind: .link)))
}

@Test func trimsTrailingPunctuation() {
    let result = links(in: "Read (https://example.com/a).")
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com/a")
}

@Test func keepsBalancedParen() {
    let md = "See https://en.wikipedia.org/wiki/Foo_(bar) now"
    let result = links(in: md)
    #expect(result[0].destination == "https://en.wikipedia.org/wiki/Foo_(bar)")
}

@Test func skipsBareURLInCodeSpan() {
    #expect(links(in: "run `https://example.com` ok").isEmpty)
}

@Test func skipsBareURLInCodeBlock() {
    #expect(links(in: "```\nhttps://example.com\n```").isEmpty)
}

@Test func skipsBareURLInsideLinkText() {
    let result = links(in: "[https://inner.example](https://outer.example)")
    #expect(result.count == 1)
    #expect(result[0].destination == "https://outer.example")
}

@Test func skipsBareURLInsideImageAlt() {
    let result = links(in: "![https://inner.example](img.png)")
    #expect(result.isEmpty)
}

@Test func requiresBoundaryBeforeURL() {
    #expect(links(in: "xhttps://example.com").isEmpty)
}

@Test func schemeOnlyIsNotALink() {
    #expect(links(in: "prefix https:// suffix").isEmpty)
}

@Test func stopsAtNonASCII() {
    let result = links(in: "リンクは https://example.com、です")
    #expect(result.count == 1)
    #expect(result[0].destination == "https://example.com")
}

@Test func httpSchemeAlsoDetected() {
    let result = links(in: "See http://example.com now")
    #expect(result[0].destination == "http://example.com")
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: `detectsBareURL` 等が FAIL

- [ ] **Step 3: 実装**

`Sources/LapermCore/HighlightMapper.swift` の Visitor を修正:

1. 深度フラグを追加(`tableDepth` の隣):

```swift
        /// リンク・画像の内側を走査中はベア URL 検出を止める(二重検出防止)
        private var inlineLinkDepth = 0
```

2. `visitLink` と `visitImage` の `descendInto` を深度フラグで包む(visitLink の例。visitImage も同様に変更):

```swift
            inlineLinkDepth += 1
            descendInto(link)
            inlineLinkDepth -= 1
```

3. `visitText` とヘルパーを追加:

```swift
        // MARK: ベア URL 検出

        /// swift-markdown は GFM autolink 拡張を有効化していないため、
        /// 裸の http(s) URL は Text ノードのまま届く。ここで自前検出する。
        mutating func visitText(_ node: Markdown.Text) {
            guard inlineLinkDepth == 0, let range = nsRange(of: node), range.length > 0
            else { return }
            appendBareURLs(in: range)
        }

        private mutating func appendBareURLs(in range: NSRange) {
            let end = NSMaxRange(range)
            var i = range.location
            while i < end {
                guard let schemeLength = urlSchemeLength(at: i, end: end) else {
                    i += 1
                    continue
                }
                // 直前が ASCII 英数字なら単語の一部("xhttps://…")なのでスキップ
                if i > 0, isASCIIAlphanumeric(text.character(at: i - 1)) {
                    i += schemeLength
                    continue
                }
                var j = i + schemeLength
                while j < end, !isURLTerminator(text.character(at: j)) { j += 1 }
                let urlEnd = trimTrailingPunctuation(from: i, to: j)
                if urlEnd > i + schemeLength {
                    let urlRange = NSRange(location: i, length: urlEnd - i)
                    let destination = text.substring(with: urlRange)
                    inlineSpans.append(HighlightSpan(range: urlRange, kind: .link))
                    linkReferences.append(LinkReference(
                        text: destination, destination: destination, range: urlRange))
                }
                i = j
            }
        }

        /// location から "https://" / "http://" が始まっていればその長さ(UTF-16)。
        private func urlSchemeLength(at location: Int, end: Int) -> Int? {
            for scheme in ["https://", "http://"] {
                let length = (scheme as NSString).length
                guard location + length <= end else { continue }
                let candidate = text.substring(
                    with: NSRange(location: location, length: length))
                if candidate.lowercased() == scheme { return length }
            }
            return nil
        }

        /// URL の終端文字: 空白・制御文字・"<"・非 ASCII(全角文字等)。
        private func isURLTerminator(_ c: unichar) -> Bool {
            c <= 0x20 || c == unichar(UnicodeScalar("<").value) || c >= 0x7F
        }

        private func isASCIIAlphanumeric(_ c: unichar) -> Bool {
            let zero = unichar(UnicodeScalar("0").value), nine = unichar(UnicodeScalar("9").value)
            let a = unichar(UnicodeScalar("a").value), z = unichar(UnicodeScalar("z").value)
            let A = unichar(UnicodeScalar("A").value), Z = unichar(UnicodeScalar("Z").value)
            return (zero...nine).contains(c) || (a...z).contains(c) || (A...Z).contains(c)
        }

        /// 末尾の約物をトリムする。")" は URL 内の括弧バランスを見て閉じ超過分のみ落とす。
        private func trimTrailingPunctuation(from start: Int, to end: Int) -> Int {
            let trailing: Set<unichar> = Set(".,;:!?'\"".utf16)
            let open = unichar(UnicodeScalar("(").value)
            let close = unichar(UnicodeScalar(")").value)
            var end = end
            while end > start {
                let c = text.character(at: end - 1)
                if trailing.contains(c) {
                    end -= 1
                    continue
                }
                if c == close {
                    var opens = 0, closes = 0
                    for k in start..<end {
                        let ch = text.character(at: k)
                        if ch == open { opens += 1 }
                        if ch == close { closes += 1 }
                    }
                    if closes > opens {
                        end -= 1
                        continue
                    }
                }
                break
            }
            return end
        }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS(既存の画像・リンクテストの回帰も含む)

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/HighlightMapper.swift Tests/LapermCoreTests/LinkDetectionTests.swift
git commit -m "feat(core): detect bare http(s) URLs as links"
```

---

### Task 4: LinkURLResolver

**Files:**
- Create: `Sources/LapermCore/LinkURLResolver.swift`
- Modify: `Sources/LapermCore/ImageURLResolver.swift`
- Test: Create `Tests/LapermCoreTests/LinkURLResolverTests.swift`

**Interfaces:**
- Consumes: なし
- Produces: `LinkURLResolver.resolve(destination: String, baseURL: URL?) -> URL?`(http / https / file / mailto + 絶対パス + 相対パス)。`ImageURLResolver.resolve` の公開挙動は不変

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/LinkURLResolverTests.swift` を新規作成(`ImageURLResolverTests.swift` と同スタイル):

```swift
import Foundation
import Testing
@testable import LapermCore

private let base = URL(filePath: "/docs/", directoryHint: .isDirectory)

@Test(arguments: [
    // (destination, baseURL あり?, 期待される絶対 URL 文字列 or nil)
    ("https://example.com/a", true, "https://example.com/a"),
    ("http://example.com/a", false, "http://example.com/a"),
    ("file:///tmp/a.md", false, "file:///tmp/a.md"),
    ("mailto:foo@example.com", false, "mailto:foo@example.com"),
    ("/tmp/a.md", false, "file:///tmp/a.md"),
    ("notes/a.md", true, "file:///docs/notes/a.md"),
    ("notes/a.md", false, nil),        // 相対パスは baseURL なしでは解決不能
    ("ftp://example.com", true, nil),  // 未対応スキーム
    ("", true, nil),                   // 空文字列
])
func resolvesLinkDestination(destination: String, hasBase: Bool, expected: String?) {
    let url = LinkURLResolver.resolve(destination: destination, baseURL: hasBase ? base : nil)
    #expect(url?.absoluteString == expected)
}

@Test func imageResolverStillRejectsMailto() {
    #expect(ImageURLResolver.resolve(destination: "mailto:a@b.c", baseURL: nil) == nil)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー(`LinkURLResolver` 未定義)

- [ ] **Step 3: 実装**

`Sources/LapermCore/LinkURLResolver.swift` を新規作成。共通ロジックを内部関数に置き、両リゾルバから使う:

```swift
import Foundation

/// リンク記法・ベア URL の URL 文字列を開ける URL へ解決する純粋関数。
/// 規則は ImageURLResolver と同じで、許可スキームに mailto が加わる。
public enum LinkURLResolver {
    public static func resolve(destination: String, baseURL: URL?) -> URL? {
        URLDestinationResolver.resolve(
            destination: destination, baseURL: baseURL,
            allowedSchemes: ["http", "https", "file", "mailto"])
    }
}

/// ImageURLResolver / LinkURLResolver の共通実装。
/// - 許可スキーム付き → そのまま
/// - "/" 始まりの絶対パス → file URL
/// - 相対パス → baseURL に対して解決(baseURL が nil なら解決不能)
/// - 空文字列・未対応スキーム → nil
enum URLDestinationResolver {
    static func resolve(
        destination: String, baseURL: URL?, allowedSchemes: Set<String>
    ) -> URL? {
        guard !destination.isEmpty else { return nil }
        // スキーム判定は URL(string:) に頼らず自前で行う(ImageURLResolver の
        // コメント参照: スキームなし相対パスでも URL(string:) は成功しうるため)。
        if let colon = destination.firstIndex(of: ":") {
            let scheme = destination[..<colon].lowercased()
            guard allowedSchemes.contains(scheme) else { return nil }
            return URL(string: destination)
        }
        if destination.hasPrefix("/") {
            return URL(filePath: destination)
        }
        guard let baseURL else { return nil }
        return URL(filePath: destination, relativeTo: baseURL).absoluteURL
    }
}
```

`Sources/LapermCore/ImageURLResolver.swift` の `resolve` 本体を委譲に差し替え(doc コメントは維持):

```swift
    public static func resolve(destination: String, baseURL: URL?) -> URL? {
        URLDestinationResolver.resolve(
            destination: destination, baseURL: baseURL,
            allowedSchemes: ["http", "https", "file"])
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS(ImageURLResolverTests の回帰も含む)

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/LinkURLResolver.swift Sources/LapermCore/ImageURLResolver.swift Tests/LapermCoreTests/LinkURLResolverTests.swift
git commit -m "feat(core): add LinkURLResolver with shared destination resolution"
```

---

### Task 5: EditingAssistant.linkifyPaste

**Files:**
- Modify: `Sources/LapermCore/EditingAssistant.swift`
- Test: `Tests/LapermCoreTests/EditingAssistantTests.swift`(追記)

**Interfaces:**
- Consumes: 既存 `EditCommand`
- Produces: `EditingAssistant.linkifyPaste(text: NSString, selection: NSRange, pasted: String) -> EditCommand?`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermCoreTests/EditingAssistantTests.swift` に追記:

```swift
// MARK: - linkifyPaste

@Test func linkifiesURLPasteOverSelection() {
    let command = EditingAssistant.linkifyPaste(
        text: "see docs here", selection: NSRange(location: 4, length: 4),
        pasted: "https://example.com")
    let replacement = "[docs](https://example.com)"
    #expect(command == EditCommand(
        replacementRange: NSRange(location: 4, length: 4),
        replacementString: replacement,
        selectedRange: NSRange(location: 4 + (replacement as NSString).length, length: 0)))
}

@Test func linkifyTrimsPastedWhitespace() {
    let command = EditingAssistant.linkifyPaste(
        text: "docs", selection: NSRange(location: 0, length: 4),
        pasted: "https://example.com\n")
    #expect(command?.replacementString == "[docs](https://example.com)")
}

@Test func linkifyRequiresSelection() {
    #expect(EditingAssistant.linkifyPaste(
        text: "docs", selection: NSRange(location: 0, length: 0),
        pasted: "https://example.com") == nil)
}

@Test func linkifyRejectsMultilineSelection() {
    #expect(EditingAssistant.linkifyPaste(
        text: "a\nb", selection: NSRange(location: 0, length: 3),
        pasted: "https://example.com") == nil)
}

@Test func linkifyRejectsNonURLPaste() {
    #expect(EditingAssistant.linkifyPaste(
        text: "docs", selection: NSRange(location: 0, length: 4),
        pasted: "hello world") == nil)
}

@Test func linkifyRejectsURLShapedSelection() {
    // URL を URL で潰す事故防止
    #expect(EditingAssistant.linkifyPaste(
        text: "https://old.example", selection: NSRange(location: 0, length: 19),
        pasted: "https://new.example") == nil)
}

@Test func linkifyRejectsSchemeOnlyPaste() {
    #expect(EditingAssistant.linkifyPaste(
        text: "docs", selection: NSRange(location: 0, length: 4),
        pasted: "https://") == nil)
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー(`linkifyPaste` 未定義)

- [ ] **Step 3: 実装**

`Sources/LapermCore/EditingAssistant.swift` の `toggleCheckbox` の後に追加:

```swift
    /// ペースト: テキスト選択中に URL をペーストしたら [選択](URL) へ変換する。
    /// 対象外なら nil(呼び出し側は通常のペーストへフォールバック)。
    /// v1 の制限: 選択が既存リンク記法・コードスパン内かどうかの文脈判定は行わない。
    public static func linkifyPaste(
        text: NSString, selection: NSRange, pasted: String
    ) -> EditCommand? {
        guard selection.length > 0, NSMaxRange(selection) <= text.length else { return nil }
        let selected = text.substring(with: selection)
        // 単一行内の選択のみ(改行またぎのリンクは作らない)
        guard !selected.contains("\n") else { return nil }
        let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isURLShaped(url), !isURLShaped(selected) else { return nil }
        let replacement = "[\(selected)](\(url))"
        return EditCommand(
            replacementRange: selection,
            replacementString: replacement,
            selectedRange: NSRange(
                location: selection.location + (replacement as NSString).length, length: 0))
    }

    /// http(s) URL 形状か: スキームで始まり、空白を含まず、スキームより長い。
    private static func isURLShaped(_ string: String) -> Bool {
        let lower = string.lowercased()
        let scheme = lower.hasPrefix("https://") ? "https://"
            : lower.hasPrefix("http://") ? "http://" : nil
        guard let scheme, string.count > scheme.count else { return false }
        return string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/LapermCore/EditingAssistant.swift Tests/LapermCoreTests/EditingAssistantTests.swift
git commit -m "feat(core): add EditingAssistant.linkifyPaste"
```

---

### Task 6: LinkOptions と Cmd+クリックで開く

**Files:**
- Create: `Sources/Laperm/LinkOptions.swift`
- Modify: `Sources/Laperm/MarkdownTextView.swift`
- Test: Create `Tests/LapermTests/LinkInteractionTests.swift`

**Interfaces:**
- Consumes: Task 1–4 の `LinkReference` / `HighlightPlan.links` / `LinkURLResolver`
- Produces: `LinkOptions(opensOnCommandClick: Bool = true, baseURL: URL? = nil)` / `MarkdownTextView.linkOptions` / `MarkdownTextView.onOpenLink: ((URL) -> Bool)?` / internal `openLink(atPoint: NSPoint) -> Bool`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/LinkInteractionTests.swift` を新規作成:

```swift
import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor
private func makeTextView(_ markdown: String) -> MarkdownTextView {
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    textView.string = markdown
    textView.highlightAll()
    return textView
}

@MainActor @Test func commandClickOnLinkCallsOnOpenLink() {
    let textView = makeTextView("See [site](https://example.com/a).")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    // "site" の中心をクリック
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    #expect(textView.openLink(atPoint: point))
    #expect(opened == URL(string: "https://example.com/a"))
}

@MainActor @Test func clickOutsideLinkDoesNotOpen() {
    let textView = makeTextView("See [site](https://example.com/a).")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    // "See" の中心をクリック
    let point = midpoint(of: NSRange(location: 0, length: 3), in: textView)
    #expect(!textView.openLink(atPoint: point))
    #expect(opened == nil)
}

@MainActor @Test func openLinkRespectsDisabledOption() {
    let textView = makeTextView("[site](https://example.com)")
    textView.linkOptions.opensOnCommandClick = false
    textView.onOpenLink = { _ in true }
    let point = midpoint(of: NSRange(location: 1, length: 4), in: textView)
    #expect(!textView.openLink(atPoint: point))
}

@MainActor @Test func bareURLIsClickable() {
    let textView = makeTextView("Go https://example.com/bare now")
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    let point = midpoint(of: NSRange(location: 3, length: 24), in: textView)
    #expect(textView.openLink(atPoint: point))
    #expect(opened == URL(string: "https://example.com/bare"))
}

@MainActor @Test func relativeLinkResolvesAgainstBaseURL() {
    let textView = makeTextView("[doc](notes/a.md)")
    textView.linkOptions.baseURL = URL(filePath: "/docs/", directoryHint: .isDirectory)
    var opened: URL?
    textView.onOpenLink = { opened = $0; return true }
    let point = midpoint(of: NSRange(location: 1, length: 3), in: textView)
    #expect(textView.openLink(atPoint: point))
    #expect(opened?.absoluteString == "file:///docs/notes/a.md")
}

@MainActor @Test func unresolvableLinkDoesNotOpen() {
    // 相対パスで baseURL なし → 解決不能 → 開かない(NSWorkspace へも渡らない)
    let textView = makeTextView("[doc](notes/a.md)")
    textView.onOpenLink = { _ in true }
    let point = midpoint(of: NSRange(location: 1, length: 3), in: textView)
    #expect(!textView.openLink(atPoint: point))
}
```

注意: テストでは必ず `onOpenLink` に `true` を返すハンドラを設定する(未設定だと実 `NSWorkspace.shared.open` が走ってしまう)。

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー(`LinkOptions` / `openLink` 未定義)

- [ ] **Step 3: 実装**

`Sources/Laperm/LinkOptions.swift` を新規作成:

```swift
import Foundation

/// リンク操作の設定。
public struct LinkOptions: Equatable, Sendable {
    /// Cmd+クリックでリンクを開く(ホバーフィードバックも連動)
    public var opensOnCommandClick: Bool
    /// 相対パスの解決基準(ImagePreviewOptions.baseURL と同じ役割)
    public var baseURL: URL?

    public init(opensOnCommandClick: Bool = true, baseURL: URL? = nil) {
        self.opensOnCommandClick = opensOnCommandClick
        self.baseURL = baseURL
    }
}
```

`Sources/Laperm/MarkdownTextView.swift` を修正:

1. プロパティを追加(`editingOptions` の隣):

```swift
    /// リンク操作の設定(デフォルト: Cmd+クリックで開く)
    public var linkOptions = LinkOptions()

    /// リンクを開く前のフック。true を返すと消費し、デフォルト動作
    /// (NSWorkspace.shared.open)を行わない。
    public var onOpenLink: ((URL) -> Bool)?
```

2. `mouseDown` を差し替え(Cmd+クリック分岐を追加):

```swift
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // deviceIndependentFlagsMask は capsLock を含み、Caps Lock 中は常時セットされるため
        // 実際に押されうる修飾キーだけを見る
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.clickCount == 1, modifiers == [.command], openLink(atPoint: point) {
            return
        }
        if editingOptions.togglesCheckboxOnClick,
            event.clickCount == 1,
            modifiers.isEmpty,
            toggleCheckbox(atPoint: point) {
            return
        }
        super.mouseDown(with: event)
    }
```

3. `toggleCheckbox` の後にリンク処理を追加:

```swift
    /// point(ビュー座標)の Cmd+クリックでリンクを開く。開いたら true。
    /// mouseDown から分離してあるのはテストで座標を直接渡せるようにするため。
    func openLink(atPoint point: NSPoint) -> Bool {
        guard linkOptions.opensOnCommandClick else { return false }
        let offset = characterIndexForInsertion(at: point)
        guard let reference = linkReference(at: offset),
            let url = LinkURLResolver.resolve(
                destination: reference.destination, baseURL: linkOptions.baseURL)
        else { return false }
        if onOpenLink?(url) == true { return true }
        NSWorkspace.shared.open(url)
        return true
    }

    /// offset を含むリンク参照(パース確定済みの currentPlan から検索)
    private func linkReference(at offset: Int) -> LinkReference? {
        markdownHighlighter.currentPlan.links.first { NSLocationInRange(offset, $0.range) }
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/LinkOptions.swift Sources/Laperm/MarkdownTextView.swift Tests/LapermTests/LinkInteractionTests.swift
git commit -m "feat(ui): open links on Cmd+click with LinkOptions and onOpenLink"
```

---

### Task 7: Cmd ホバーフィードバック(下線 + ポインティングハンド)

**Files:**
- Modify: `Sources/Laperm/MarkdownTextView.swift`
- Test: `Tests/LapermTests/LinkInteractionTests.swift`(追記)

**Interfaces:**
- Consumes: Task 6 の `linkReference(at:)` / `linkOptions`
- Produces: internal `refreshLinkHover(atPoint: NSPoint, commandHeld: Bool)` / テスト用 `debugHoveredLinkRange: NSRange?`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/LinkInteractionTests.swift` に追記:

```swift
@MainActor @Test func hoverWithCommandOverLinkSetsHoveredRange() {
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    let md = "See [site](https://example.com/a)."
    #expect(textView.debugHoveredLinkRange
        == (md as NSString).range(of: "[site](https://example.com/a)"))
}

@MainActor @Test func hoverWithoutCommandClearsHoveredRange() {
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    textView.refreshLinkHover(atPoint: point, commandHeld: false)
    #expect(textView.debugHoveredLinkRange == nil)
}

@MainActor @Test func hoverAppliesAndRemovesUnderline() {
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    #expect(hasUnderlineRenderingAttribute(in: textView))
    textView.refreshLinkHover(atPoint: point, commandHeld: false)
    #expect(!hasUnderlineRenderingAttribute(in: textView))
}

@MainActor @Test func textChangeClearsHoveredRange() {
    let textView = makeTextView("See [site](https://example.com/a).")
    let point = midpoint(of: NSRange(location: 5, length: 4), in: textView)
    textView.refreshLinkHover(atPoint: point, commandHeld: true)
    textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
    #expect(textView.debugHoveredLinkRange == nil)
}

@MainActor
private func hasUnderlineRenderingAttribute(in textView: MarkdownTextView) -> Bool {
    let layoutManager = textView.textLayoutManager!
    var found = false
    layoutManager.enumerateRenderingAttributes(
        from: layoutManager.documentRange.location, reverse: false
    ) { _, attributes, _ in
        if attributes[.underlineStyle] != nil { found = true }
        return !found
    }
    return found
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー(`refreshLinkHover` 未定義)

- [ ] **Step 3: 実装**

`Sources/Laperm/MarkdownTextView.swift` を修正:

1. プロパティを追加(`barInsertionPointColor` の隣):

```swift
    private var hoveredLinkRange: NSRange?
    private var linkTrackingArea: NSTrackingArea?

    /// テスト用: 現在ホバー中のリンクレンジ。
    var debugHoveredLinkRange: NSRange? { hoveredLinkRange }
```

2. トラッキングエリアとイベントを追加(`// MARK: - 入力インターセプト` の前に `// MARK: - リンクホバー` セクションとして):

```swift
    // MARK: - リンクホバー

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = linkTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        linkTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshLinkHover(
            atPoint: convert(event.locationInWindow, from: nil),
            commandHeld: event.modifierFlags.contains(.command))
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Cmd の押下/解放時はポインタが動かなくてもホバー状態を更新する
        let location = window?.mouseLocationOutsideOfEventStream ?? .zero
        refreshLinkHover(
            atPoint: convert(location, from: nil),
            commandHeld: event.modifierFlags.contains(.command))
    }

    /// Cmd+ホバーの下線・カーソル形状を更新する。
    /// mouseMoved / flagsChanged から分離してあるのはテストで直接呼べるようにするため。
    func refreshLinkHover(atPoint point: NSPoint, commandHeld: Bool) {
        var newRange: NSRange?
        if commandHeld, linkOptions.opensOnCommandClick {
            newRange = linkReference(at: characterIndexForInsertion(at: point))?.range
        }
        guard newRange != hoveredLinkRange else { return }
        setLinkUnderline(hoveredLinkRange, enabled: false)
        setLinkUnderline(newRange, enabled: true)
        hoveredLinkRange = newRange
        if newRange != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    /// ホバー下線の renderingAttributes を付け外しする(再レイアウトなし)。
    /// テーマの .link スタイルは色のみで underline を使わないため衝突しない。
    private func setLinkUnderline(_ range: NSRange?, enabled: Bool) {
        guard let range,
            let layoutManager = textLayoutManager,
            let contentManager = layoutManager.textContentManager,
            let textRange = contentManager.textRange(for: range)
        else { return }
        if enabled {
            layoutManager.addRenderingAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, for: textRange)
        } else {
            layoutManager.removeRenderingAttribute(.underlineStyle, for: textRange)
        }
    }

    /// 編集でレンジがずれるため、ホバー状態は編集のたびに破棄する。
    private func clearLinkHover() {
        setLinkUnderline(hoveredLinkRange, enabled: false)
        hoveredLinkRange = nil
    }
```

3. 既存の `didChangeText()` に 1 行追加:

```swift
    public override func didChangeText() {
        super.didChangeText()
        clearLinkHover()
        updateInsertionPointOverlay()
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/MarkdownTextView.swift Tests/LapermTests/LinkInteractionTests.swift
git commit -m "feat(ui): show underline and pointing hand on Cmd+hover over links"
```

---

### Task 8: URL ペーストのリンク化(UI 経路)

**Files:**
- Modify: `Sources/Laperm/EditingOptions.swift`
- Modify: `Sources/Laperm/MarkdownTextView.swift`
- Test: `Tests/LapermTests/LinkInteractionTests.swift`(追記)

**Interfaces:**
- Consumes: Task 5 の `EditingAssistant.linkifyPaste`
- Produces: `EditingOptions.linkifiesPastedURL: Bool = true` / internal `applyLinkifiedPaste(_ pasted: String) -> Bool` / `paste(_:)` オーバーライド

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/LinkInteractionTests.swift` に追記:

```swift
@MainActor @Test func pasteURLOverSelectionLinkifies() {
    let textView = makeTextView("see docs here")
    textView.setSelectedRange(NSRange(location: 4, length: 4))
    #expect(textView.applyLinkifiedPaste("https://example.com"))
    #expect(textView.string == "see [docs](https://example.com) here")
}

@MainActor @Test func pasteURLWithoutSelectionFallsBack() {
    let textView = makeTextView("see docs here")
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(!textView.applyLinkifiedPaste("https://example.com"))
    #expect(textView.string == "see docs here")
}

@MainActor @Test func pasteLinkifyRespectsDisabledOption() {
    let textView = makeTextView("see docs here")
    textView.editingOptions.linkifiesPastedURL = false
    textView.setSelectedRange(NSRange(location: 4, length: 4))
    #expect(!textView.applyLinkifiedPaste("https://example.com"))
}

@MainActor @Test func pasteLinkifyUndoesInOneStep() {
    let textView = makeTextView("see docs here")
    let undoProvider = UndoManagerProvider()
    textView.delegate = undoProvider
    textView.setSelectedRange(NSRange(location: 4, length: 4))
    #expect(textView.applyLinkifiedPaste("https://example.com"))
    undoProvider.manager.undo()
    #expect(textView.string == "see docs here")
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー(`linkifiesPastedURL` / `applyLinkifiedPaste` 未定義)

- [ ] **Step 3: 実装**

`Sources/Laperm/EditingOptions.swift` にプロパティを追加(既存 4 つと同様に doc コメント付き・init のデフォルト true):

```swift
    /// テキスト選択中に URL をペーストしたら [選択](URL) へ変換する
    public var linkifiesPastedURL: Bool
```

init は既存パターンどおり `linkifiesPastedURL: Bool = true` を末尾に追加して代入する。

`Sources/Laperm/MarkdownTextView.swift` の `// MARK: - 編集支援` セクション(`deleteBackward` の後)に追加:

```swift
    public override func paste(_ sender: Any?) {
        if let pasted = NSPasteboard.general.string(forType: .string),
            applyLinkifiedPaste(pasted) {
            return
        }
        super.paste(sender)
    }

    /// ペースト文字列がリンク化条件を満たせば適用して true。
    /// paste から分離してあるのはテストでペースト文字列を直接渡せるようにするため。
    func applyLinkifiedPaste(_ pasted: String) -> Bool {
        guard editingOptions.linkifiesPastedURL, !hasMarkedText(),
            let command = EditingAssistant.linkifyPaste(
                text: string as NSString, selection: selectedRange(), pasted: pasted)
        else { return false }
        return perform(command)
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/EditingOptions.swift Sources/Laperm/MarkdownTextView.swift Tests/LapermTests/LinkInteractionTests.swift
git commit -m "feat(ui): linkify pasted URL over selection"
```

---

### Task 9: SwiftUI モディファイア

**Files:**
- Modify: `Sources/Laperm/MarkdownEditorView.swift`
- Modify: `docs/superpowers/specs/2026-07-17-link-interaction-design.md`(モディファイア名の修正)
- Test: `Tests/LapermTests/MarkdownEditorViewTests.swift`(追記)

**Interfaces:**
- Consumes: Task 6 の `MarkdownTextView.linkOptions` / `onOpenLink`
- Produces: `MarkdownEditorView.linkOptions(_:)` / `MarkdownEditorView.onOpenLink(_:)`

命名メモ: スペックでは `.markdownLinkOptions` / `.onMarkdownOpenLink` としたが、既存モディファイア(`imagePreviewOptions` 等)は接頭辞なしで統一されているため `.linkOptions` / `.onOpenLink` に変更する。スペック側をこの名前に修正する。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/LapermTests/MarkdownEditorViewTests.swift` に追記(既存テストの `apply(to:)` 利用パターンに合わせる。既存テストの書き方を 1 つ確認してから書くこと):

```swift
@MainActor @Test func linkModifiersApplyToTextView() {
    let base = URL(filePath: "/docs/", directoryHint: .isDirectory)
    var openedURLs: [URL] = []
    let view = MarkdownEditorView(text: .constant("[a](b.md)"))
        .linkOptions(LinkOptions(opensOnCommandClick: true, baseURL: base))
        .onOpenLink { openedURLs.append($0); return true }
    let textView = MarkdownTextView()
    view.apply(to: textView)
    #expect(textView.linkOptions == LinkOptions(opensOnCommandClick: true, baseURL: base))
    #expect(textView.onOpenLink?(URL(string: "https://example.com")!) == true)
    #expect(openedURLs == [URL(string: "https://example.com")!])
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test`
Expected: コンパイルエラー(モディファイア未定義)

- [ ] **Step 3: 実装**

`Sources/Laperm/MarkdownEditorView.swift` を修正:

1. stored property を追加(`imageLoader` の隣):

```swift
    private var linkOptions = LinkOptions()
    private var onOpenLink: ((URL) -> Bool)?
```

2. モディファイアを追加(`imageLoader(_:)` の後):

```swift
    /// リンク操作の設定(Cmd+クリックで開く・相対パスの baseURL)。
    public func linkOptions(_ options: LinkOptions) -> MarkdownEditorView {
        var copy = self
        copy.linkOptions = options
        return copy
    }

    /// リンクを開く前のフック。true を返すと消費(デフォルトの NSWorkspace.open を行わない)。
    public func onOpenLink(_ handler: @escaping (URL) -> Bool) -> MarkdownEditorView {
        var copy = self
        copy.onOpenLink = handler
        return copy
    }
```

3. `apply(to:)` に反映を追加(`imageLoader` の行の後):

```swift
        textView.linkOptions = linkOptions
        textView.onOpenLink = onOpenLink
```

4. スペック `docs/superpowers/specs/2026-07-17-link-interaction-design.md` の SwiftUI 節を実名に合わせて修正:
   `.markdownLinkOptions(_ options: LinkOptions)` → `.linkOptions(_ options: LinkOptions)`、
   `.onMarkdownOpenLink(_ handler:)` → `.onOpenLink(_ handler:)`(既存モディファイアの命名規約に合わせた旨を一行追記)。

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/Laperm/MarkdownEditorView.swift Tests/LapermTests/MarkdownEditorViewTests.swift docs/superpowers/specs/2026-07-17-link-interaction-design.md
git commit -m "feat(ui): add linkOptions and onOpenLink SwiftUI modifiers"
```

---

### Task 10: Example アプリ更新と GUI 検証

**Files:**
- Modify: `Example/ExampleMacOS/ContentView.swift`

**Interfaces:**
- Consumes: Task 9 の SwiftUI モディファイア
- Produces: リンクサンプル入りデモ文書、開いた URL を表示するステータスバー

- [ ] **Step 1: ContentView にリンクデモを追加**

`Example/ExampleMacOS/ContentView.swift` を修正:

1. `@State` を追加(`editorProxy` の隣):

```swift
    @State private var lastOpenedURL: URL?
```

2. `MarkdownEditorView` のモディファイアチェーンに追加(`.imagePreviewOptions` の行の後):

```swift
            .linkOptions(.init(baseURL: imageDirectory))
            .onOpenLink { url in
                lastOpenedURL = url
                // デモではブラウザを起動せずステータスバーに表示するだけ
                return true
            }
```

3. `safeAreaInset` の `VStack` 化(vim ステータスとリンクステータスを両方出す):

```swift
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let status = vim.statusText {
                        Text(status)
                            .font(.system(.caption, design: .monospaced).bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.bar)
                    }
                    if let url = lastOpenedURL {
                        Text("開いたリンク: \(url.absoluteString)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.bar)
                    }
                }
            }
```

4. `sampleDocument` の「## 画像」節の前にリンク節を追加:

```markdown
    ## リンク

    - [インラインリンク](https://example.com/inline) を Cmd+クリック
    - 参照リンク: [Laperm リポジトリ][repo]
    - ベア URL: https://example.com/bare も開けます
    - 相対パス: [サンプル画像を開く](sample.png)
    - 選択して URL をペーストするとリンク化されます

    [repo]: https://example.com/repo
```

- [ ] **Step 2: Example をビルド**

Run: `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: GUI 検証(verifying-macos-gui スキルに従う)**

プロジェクトスキル `.claude/skills/verifying-macos-gui/SKILL.md` を必ず読み、その手順でアプリを起動して以下を確認する:

1. **Cmd+クリック**: インラインリンクを Cmd+クリック → ステータスバーに `開いたリンク: https://example.com/inline` が出る(スクリーンショット)
2. **ベア URL**: `https://example.com/bare` を Cmd+クリック → ステータスバーに表示される
3. **相対パス**: `サンプル画像を開く` を Cmd+クリック → `file://…/sample.png` が表示される
4. **ホバー**: Cmd を押しながらリンク上にポインタを置く → 下線が表示される(スクリーンショットで確認。カーソル形状はスクリーンショットに写らないため下線で判定)
5. **通常クリック**: Cmd なしのクリックではリンクが開かず、カーソルが移動するだけ
6. **ペーストリンク化**: 本文中のテキストを選択し、`pbcopy` で `https://pasted.example` をクリップボードに入れて Cmd+V → `[選択](https://pasted.example)` に変わる(スクリーンショット)

- [ ] **Step 4: 全テストを実行**

Run: `swift test`
Expected: 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Example/ExampleMacOS/ContentView.swift
git commit -m "feat(example): add link interaction demo with opened-URL status bar"
```

---

## 完了条件

- `swift test` 全パス
- Example アプリで GUI 検証 6 項目すべて確認済み(verifying-macos-gui スキル準拠)
- 全コミットに Task context トレーラ付与
