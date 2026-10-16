import Foundation
import Testing
@testable import LapermCore

// Completion(Laperm ADR 0047)のきっかけの検出と確定の編集。

private func detect(_ markdown: String, caret: Int? = nil, parsed: Bool = true, planIsCurrent: Bool = false) -> CompletionQuery? {
    let plan = parsed ? MarkdownParser().highlightPlan(for: markdown) : HighlightPlan()
    return CompletionTrigger.detect(text: markdown as NSString, caret: caret ?? (markdown as NSString).length, plan: plan, planIsCurrent: planIsCurrent)
}

private func range(of needle: String, in markdown: String) -> NSRange {
    (markdown as NSString).range(of: needle)
}

@Test func doubleBracketStartsANoteTitleQueryWithTheTypedText() {
    let query = detect("See [[Wi")
    #expect(query?.kind == .noteTitle)
    #expect(query?.text == "Wi")
    #expect(query?.range == NSRange(location: 6, length: 2))
    #expect(query?.anchor == 4)
}

@Test func doubleBracketAloneQueriesEveryNote() {
    let query = detect("[[")
    #expect(query?.kind == .noteTitle)
    #expect(query?.text == "")
    #expect(query?.range == NSRange(location: 2, length: 0))
}

@Test func closingBracketsAfterTheCaretDoNotMatter() {
    // `completesPairs` が `[[]]` を作るので、キャレットは `]]` の前にある
    let text = "[[Wi]]"
    let query = detect(text, caret: 4)
    #expect(query?.kind == .noteTitle)
    #expect(query?.text == "Wi")
    #expect(query?.range == NSRange(location: 2, length: 2))
}

@Test func theRangeCoversTheRestOfTheWordAfterTheCaret() {
    // `[[Wiki]]` の `i` を消した `[[Wki]]`: 絞り込みは `W`、置き換えは `Wki` 全体(`|` や `#` の手前まで)
    let text = "[[Wki]]"
    let query = detect(text, caret: 3)
    #expect(query?.text == "W")
    #expect(query?.range == NSRange(location: 2, length: 3))
    let command = CompletionTrigger.command(for: query!, item: CompletionItem(title: "Wiki", insertionText: "Wiki"), in: text as NSString)!
    #expect((text as NSString).replacingCharacters(in: command.replacementRange, with: command.replacementString) == "[[Wiki]]")
    #expect(command.selectedRange == NSRange(location: 8, length: 0))
    let aliased = "[[Wki|shown]] x"
    #expect(detect(aliased, caret: 3)?.range == NSRange(location: 2, length: 3))
    let headed = "[[Wki#Sec]]"
    #expect(detect(headed, caret: 3)?.range == NSRange(location: 2, length: 3))
    #expect(detect(headed, caret: 7)?.range == NSRange(location: 6, length: 3))
    #expect(detect(headed, caret: 7)?.text == "S")
    // Tag も語の続きまで
    let tag = "---\ntags: [swift, b]\n---\n"
    let swift = (tag as NSString).range(of: "swift")
    #expect(detect(tag, caret: swift.location + 2)?.text == "sw")
    #expect(detect(tag, caret: swift.location + 2)?.range == swift)
}

@Test func hashSwitchesToTheHeadingsOfTheNamedNote() {
    let query = detect("[[Welcome#Sec")
    #expect(query?.kind == .heading(note: "Welcome"))
    #expect(query?.text == "Sec")
    #expect(query?.range == NSRange(location: 10, length: 3))
    #expect(query?.anchor == 0)
    // `[[#` は今の Note
    #expect(detect("[[#")?.kind == .heading(note: ""))
    #expect(detect("[[ Welcome #")?.kind == .heading(note: "Welcome"))
}

@Test func aliasClosedLinkAndSingleBracketDoNotTrigger() {
    #expect(detect("[[Note|al") == nil)
    #expect(detect("[[Note]] and") == nil)
    #expect(detect("[Wi") == nil)
    #expect(detect("[[Wi]] [x") == nil)
    // 閉じた Wiki Link の中のキャレット(`]` の前)は閉じたまま
    #expect(detect("[[Note]]", caret: 8) == nil)
}

@Test func escapedAndEmbedBracketsDoNotTrigger() {
    #expect(detect("\\[[Wi") == nil)
    #expect(detect("![[image") == nil)
    // 2 つのバックスラッシュはエスケープではない
    #expect(detect("\\\\[[Wi")?.kind == .noteTitle)
}

@Test func codeAndLinkDestinationsDoNotTrigger() {
    #expect(detect("Run `[[Wi") == nil)
    #expect(detect("``` \n[[Wi") == nil)
    #expect(detect("```\ncode\n```\n[[Wi")?.kind == .noteTitle)
    #expect(detect("~~~\n[[Wi") == nil)
    #expect(detect("    indented\n[[Wi")?.kind == .noteTitle)
    #expect(detect("[text](http://x/[[Wi") == nil)
    #expect(detect("[text](http://x) [[Wi")?.kind == .noteTitle)
    // 再パース前(計画が無い)でもコードフェンスは文字で数える
    #expect(detect("```\n[[Wi", parsed: false) == nil)
    #expect(detect("a `code` [[Wi")?.kind == .noteTitle)
}

@Test func fencesAreMatchedByCharacterAndLengthAndInsideQuotes() {
    // 4 つで開いたフェンスの中の 3 つの行は閉じない(CommonMark): 閉じた後は普通に出る
    #expect(detect("````\n```\n````\n[[Wi", parsed: false)?.kind == .noteTitle)
    #expect(detect("````\n```\n[[Wi", parsed: false) == nil)
    // 記号が違えば閉じない
    #expect(detect("```\n~~~\n[[Wi", parsed: false) == nil)
    // 閉じの行に記号以外があれば閉じない
    #expect(detect("```\n``` x\n[[Wi", parsed: false) == nil)
    // 引用の中のフェンス
    #expect(detect("> ```\n> [[Wi", parsed: false) == nil)
    #expect(detect("> ```\n> code\n> ```\n> [[Wi", parsed: false)?.kind == .noteTitle)
}

@Test func backtickRunsAreMatchedByLength() {
    // 2 つで開いたコードスパンは 1 つでは閉じない
    #expect(detect("a ``code `[[Wi", parsed: false) == nil)
    #expect(detect("a ``x`` [[Wi", parsed: false)?.kind == .noteTitle)
    #expect(detect("a `x` `y` [[Wi", parsed: false)?.kind == .noteTitle)
    #expect(detect("a \\` [[Wi", parsed: false)?.kind == .noteTitle)
}

@Test func balancedParenthesesInsideALinkDestination() {
    #expect(detect("[x](https://x/(a)/[[Wi") == nil)
    #expect(detect("[x](https://x/(a)) [[Wi")?.kind == .noteTitle)
    #expect(detect("[x](https://x/\\)/[[Wi") == nil)
    #expect(detect("f(a) [[Wi")?.kind == .noteTitle)
}

@Test func aCurrentPlanIsTrustedOverTheTextualScan() {
    // 計画が今の本文なら文字は読まない(空の計画 + current = コードブロック無し)
    #expect(detect("```\n[[Wi", parsed: false, planIsCurrent: true)?.kind == .noteTitle)
    #expect(detect("```\n[[Wi", parsed: true, planIsCurrent: true) == nil)
    #expect(detect("a `[[Wi", parsed: false, planIsCurrent: true)?.kind == .noteTitle)
    // Front Matter も計画のもの
    let fm = "---\ntags: [sw]\n---\n"
    #expect(detect(fm, caret: 13, parsed: false, planIsCurrent: true) == nil)
    #expect(detect(fm, caret: 13, parsed: true, planIsCurrent: true)?.kind == .tag)
}

@Test func indentedCodeBlockFromThePlanDoesNotTrigger() {
    let text = "para\n\n    code [[Wi"
    #expect(detect(text) == nil)
}

@Test func yamlCommentsQuotesAndNestingInTagValues() {
    // 空白の後ろの `#` は YAML のコメント
    let comment = "---\ntags: #sw\n---\n"
    #expect(detect(comment, caret: range(of: "sw", in: comment).location + 2) == nil)
    let itemComment = "---\ntags:\n  - #sw\n---\n"
    #expect(detect(itemComment, caret: range(of: "sw", in: itemComment).location + 2) == nil)
    let listComment = "---\ntags: [a, #sw]\n---\n"
    #expect(detect(listComment, caret: range(of: "sw", in: listComment).location + 2) == nil)
    // `[` や引用符の直後の `#` は値
    let quotedHash = "---\ntags: [\"#sw\"]\n---\n"
    #expect(detect(quotedHash, caret: range(of: "sw", in: quotedHash).location + 2)?.text == "sw")
    // 引用符の中のカンマは区切りでない(語に空白があるので出ない)
    let quotedComma = "---\ntags: [\"a, sw\"]\n---\n"
    #expect(detect(quotedComma, caret: range(of: "sw", in: quotedComma).location + 2) == nil)
    // 入れ子のリストは Tag ではない
    let nested = "---\ntags: [a, [b, sw]]\n---\n"
    #expect(detect(nested, caret: range(of: "sw", in: nested).location + 2) == nil)
}

@Test func frontMatterTagValuesTrigger() {
    let text = "---\ntags: [swift, io\n---\n"
    let query = detect(text, caret: range(of: "io", in: text).location + 2)
    #expect(query?.kind == .tag)
    #expect(query?.text == "io")
    #expect(query?.range == range(of: "io", in: text))
    // `]` が後ろにあっても(completesPairs)値の中
    let closed = "---\ntags: [sw]\n---\n"
    #expect(detect(closed, caret: range(of: "sw", in: closed).location + 2)?.text == "sw")
    // 文字列 1 つ、カンマ区切り、`tag` キー、引用符、`#`
    let scalar = "---\ntag: Sw\n---\n"
    #expect(detect(scalar, caret: range(of: "Sw", in: scalar).location + 2)?.text == "Sw")
    let comma = "---\ntags: a, b\n---\n"
    #expect(detect(comma, caret: range(of: "b", in: comma).location + 1)?.text == "b")
    let quoted = "---\ntags: [\"sw\"]\n---\n"
    #expect(detect(quoted, caret: range(of: "sw", in: quoted).location + 2)?.text == "sw")
    let hashed = "---\ntags: [#sw]\n---\n"
    #expect(detect(hashed, caret: range(of: "sw", in: hashed).location + 2)?.text == "sw")
}

@Test func frontMatterBlockListItemsTrigger() {
    let text = "---\ntitle: x\ntags:\n  - alpha\n  # note\n  - be\n---\n"
    let query = detect(text, caret: range(of: "be", in: text).location + 2)
    #expect(query?.kind == .tag)
    #expect(query?.text == "be")
    // 別のキーのリストでは出ない
    let other = "---\nauthors:\n  - be\n---\n"
    #expect(detect(other, caret: range(of: "be", in: other).location + 2) == nil)
}

@Test func frontMatterNonTagPositionsDoNotTrigger() {
    let text = "---\ntitle: Wi\ntags: [a]\n---\n[[Wi"
    #expect(detect(text, caret: range(of: "Wi", in: text).location + 2) == nil)
    // 値が空(キャレットが入っただけ)では出さない
    let empty = "---\ntags: \n---\n"
    #expect(detect(empty, caret: 10) == nil)
    // `]` の後ろは値の外
    let after = "---\ntags: [a] b\n---\n"
    #expect(detect(after, caret: range(of: "] b", in: after).location + 3) == nil)
    // Tag の文字でない語(空白、`:`)は出さない
    let spaced = "---\ntags: [two words\n---\n"
    #expect(detect(spaced, caret: range(of: "words", in: spaced).location + 5) == nil)
    // Front Matter の後ろの `[[` は普通に出る
    #expect(detect(text)?.kind == .noteTitle)
    // フェンスの行自体では出ない
    #expect(detect("---\ntags: [a]\n---", caret: 3) == nil)
}

@Test func confirmingANoteTitleCompletesTheWikiLink() {
    let text = "See [[Wi"
    let query = detect(text)!
    let item = CompletionItem(title: "Wiki", detail: "", insertionText: "Wiki")
    let command = CompletionTrigger.command(for: query, item: item, in: text as NSString)
    #expect(command == EditCommand(replacementRange: NSRange(location: 6, length: 2), replacementString: "Wiki]]",
                                   selectedRange: NSRange(location: 12, length: 0)))
}

@Test func confirmingReusesExistingClosingBrackets() {
    let text = "See [[Wi]] after"
    let query = detect(text, caret: 8)!
    let item = CompletionItem(title: "Wiki", insertionText: "Sub/Wiki")
    let command = CompletionTrigger.command(for: query, item: item, in: text as NSString)!
    #expect(command.replacementString == "Sub/Wiki")
    #expect(command.replacementRange == NSRange(location: 6, length: 2))
    #expect(command.selectedRange == NSRange(location: 16, length: 0))
    let applied = (text as NSString).replacingCharacters(in: command.replacementRange, with: command.replacementString)
    #expect(applied == "See [[Sub/Wiki]] after")
    #expect((applied as NSString).substring(to: command.selectedRange.location) == "See [[Sub/Wiki]]")
}

@Test func confirmingInsideAnAliasedLinkKeepsTheAliasAndMovesPastTheClosing() {
    let text = "[[Wi|shown]] x"
    let query = detect(text, caret: 4)!
    let command = CompletionTrigger.command(for: query, item: CompletionItem(title: "Wiki", insertionText: "Wiki"), in: text as NSString)!
    #expect(command.replacementString == "Wiki")
    let applied = (text as NSString).replacingCharacters(in: command.replacementRange, with: command.replacementString)
    #expect(applied == "[[Wiki|shown]] x")
    #expect(command.selectedRange == NSRange(location: 14, length: 0))
    // 見出しが続くときも同じ
    let headed = "[[Wi#Sec]]"
    let headedCommand = CompletionTrigger.command(for: detect(headed, caret: 4)!, item: CompletionItem(title: "Wiki", insertionText: "Wiki"), in: headed as NSString)!
    #expect(headedCommand.selectedRange == NSRange(location: 12, length: 0))
    // `]]` が無い `[[Wi|shown` は足す
    let open = "[[Wi|shown"
    let openCommand = CompletionTrigger.command(for: detect(open, caret: 4)!, item: CompletionItem(title: "Wiki", insertionText: "Wiki"), in: open as NSString)!
    #expect(openCommand.replacementString == "Wiki]]")
}

@Test func confirmingAHeadingCompletesTheLink() {
    let text = "[[Welcome#Se]]"
    let query = detect(text, caret: 12)!
    let command = CompletionTrigger.command(for: query, item: CompletionItem(title: "Second", detail: "H2", insertionText: "Second"), in: text as NSString)!
    let applied = (text as NSString).replacingCharacters(in: command.replacementRange, with: command.replacementString)
    #expect(applied == "[[Welcome#Second]]")
    #expect(command.selectedRange == NSRange(location: 18, length: 0))
}

@Test func confirmingATagReplacesOnlyTheWord() {
    let text = "---\ntags: [sw]\n---\n"
    let query = detect(text, caret: range(of: "sw", in: text).location + 2)!
    let command = CompletionTrigger.command(for: query, item: CompletionItem(title: "swift", insertionText: "swift"), in: text as NSString)!
    let applied = (text as NSString).replacingCharacters(in: command.replacementRange, with: command.replacementString)
    #expect(applied == "---\ntags: [swift]\n---\n")
    #expect(command.selectedRange == NSRange(location: range(of: "swift", in: applied).location + 5, length: 0))
}

@Test func commandOutsideTheDocumentIsNil() {
    let query = CompletionQuery(kind: .noteTitle, text: "x", range: NSRange(location: 5, length: 3), anchor: 3)
    #expect(CompletionTrigger.command(for: query, item: CompletionItem(title: "x", insertionText: "x"), in: "[[x") == nil)
}
