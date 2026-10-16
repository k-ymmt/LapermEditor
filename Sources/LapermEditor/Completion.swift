import Foundation
import LapermCore
import Observation

/// Completion の候補の供給元(ホストが注入する。Laperm ADR 0047)。編集部品はきっかけの検出・一覧・キー操作・挿入を持ち、
/// 候補(Note のタイトル、見出し、Tag)がどこから来るかは知らない。注入されなければ Completion は起きない。
///
/// 打ちかけの文字と種類を受け取り、絞り込み・並び・上限まで済んだ候補の列を返す(前方一致 → 部分一致、ツリー順、50 件まで。
/// 比較は大文字小文字を区別せず NFC で: Wiki Link の解決と同じ)。空なら一覧は出ない。打鍵のたびにメインアクターで同期に
/// 呼ばれるので、1 回は数 ms に収めること。
@MainActor
public protocol CompletionProvider: AnyObject {
    func completions(for query: CompletionQuery) -> [CompletionItem]
}

/// Completion の設定(`LinkPreviewOptions` と並ぶ)。
public struct CompletionOptions: Equatable, Sendable {
    /// 有効 / 無効。無効ならきっかけの検出もプロバイダの呼び出しもしない。
    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}

/// Completion List の状態の公開(iOS のキーボードアクセサリの段がこれを読む。Laperm ADR 0047)。ホストが 1 つ作って
/// `MarkdownEditorView.completionList(_:)` で渡し、編集部品が中身を書く。`items` が空なら Completion 中ではない。
/// タップでの確定は `choose(_:)`(IME の変換中でも受け、未確定の文字ごと候補に置き換える)。
///
/// 同じ状態を複数のテキストビューが使ってよい(iPhone のタブごとのエディタ): 一覧を開いているビュー(持ち主)だけが中身を書き、
/// `choose` はその持ち主に届く。持ち主でないビューが閉じても中身は消えない。
@MainActor @Observable
public final class CompletionListState {
    public private(set) var items: [CompletionItem] = []
    /// キー操作で選ばれている行(`items` が空なら意味を持たない)。
    public private(set) var selectedIndex = 0
    /// ビュー(持ち主の候補)ごとの確定の処理。
    @ObservationIgnored private var commits: [ObjectIdentifier: (CompletionItem) -> Void] = [:]
    /// 今の一覧を開いているビュー。
    @ObservationIgnored private var activeOwner: ObjectIdentifier?

    public init() {}

    public var isActive: Bool { !items.isEmpty }

    public func choose(_ item: CompletionItem) {
        guard let activeOwner, let commit = commits[activeOwner] else { return }
        commit(item)
    }

    func register(owner: AnyObject, commit: @escaping (CompletionItem) -> Void) {
        commits[ObjectIdentifier(owner)] = commit
    }

    /// 持ち主をやめる(ビューの付け替え・破棄)。一覧を開いていたなら空にする。
    func unregister(owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        commits[id] = nil
        if activeOwner == id {
            activeOwner = nil
            update(items: [], selectedIndex: 0)
        }
    }

    /// 一覧の中身を書く。空(閉じた)は持ち主からだけ受け、空でなければそのビューが持ち主になる。
    func publish(owner: AnyObject, items: [CompletionItem], selectedIndex: Int) {
        let id = ObjectIdentifier(owner)
        if items.isEmpty {
            guard activeOwner == id else { return }
            activeOwner = nil
        } else {
            activeOwner = id
        }
        update(items: items, selectedIndex: selectedIndex)
    }

    private func update(items: [CompletionItem], selectedIndex: Int) {
        if self.items != items { self.items = items }
        if self.selectedIndex != selectedIndex { self.selectedIndex = selectedIndex }
    }
}

/// Completion 中のキー操作の結果。
enum CompletionKeyAction: Equatable {
    case moveUp, moveDown, commit, dismiss
    /// 一覧を閉じ、キーはテキストビューに流す(← → など、キャレットを動かすキー)。
    case closeAndPassThrough
}

/// Completion の状態(AppKit / UIKit の MarkdownTextView が共有)。きっかけの検出(`CompletionTrigger`)の結果をプロバイダに渡し、
/// 一覧(セッション)を持ち、キー操作と確定を決める。見せ方(macOS のパネル、iOS の段)はビューの仕事で、`onSessionChange` で知る。
@MainActor
final class CompletionController {
    struct Session: Equatable {
        var query: CompletionQuery
        var items: [CompletionItem]
        var selectedIndex: Int

        var selectedItem: CompletionItem { items[selectedIndex] }
    }

    /// 差し替えると(nil でなくても)開いている一覧と Esc の記憶を捨てる: 前の供給元の候補を確定させない。
    var provider: (any CompletionProvider)? {
        didSet {
            guard provider !== oldValue else { return }
            dismissedAnchor = nil
            close()
        }
    }
    var options = CompletionOptions() {
        didSet { if !options.isEnabled { close() } }
    }
    /// ホストが渡した一覧の状態(iOS の段)。ビューの確定の処理(`commit`)を持ち主として登録する。
    var listState: CompletionListState? {
        didSet {
            guard oldValue !== listState else { return }
            oldValue?.unregister(owner: self)
            listState?.register(owner: self) { [weak self] item in self?.commit?(item) }
            publish()
        }
    }
    /// 一覧の確定(パネルのクリック、段のタップ、キー)をビューの編集に変える。ビューが設定する。
    var commit: ((CompletionItem) -> Void)?
    private(set) var session: Session? {
        didSet {
            guard session != oldValue else { return }
            publish()
            onSessionChange?()
        }
    }
    /// Esc で閉じたきっかけ(`CompletionQuery.anchor`)。キャレットがその `[[` の外へ出るか、きっかけが消えるまで開き直さない。
    private(set) var dismissedAnchor: Int?
    var onSessionChange: (() -> Void)?

    /// 打鍵の後(文字の挿入・削除、IME の未確定文字の変化、ペア補完)。きっかけがあれば候補を取り、一覧を開く / 更新する。
    /// IME の変換中は `markedRange` を渡す: 変換中の選択(変換する文節)は選択ではなく、キャレットは未確定文字の末尾として扱う。
    /// `planIsCurrent` は計画が今の本文を表しているか(再パース済み。古ければ検出が文字でも読む)。
    func noteTyping(text: NSString, caret: NSRange, markedRange: NSRange? = nil, plan: HighlightPlan, planIsCurrent: Bool = false) {
        let caret = markedRange.map { NSRange(location: NSMaxRange($0), length: 0) } ?? caret
        guard options.isEnabled, let provider, caret.length == 0,
              let query = CompletionTrigger.detect(text: text, caret: caret.location, plan: plan, planIsCurrent: planIsCurrent)
        else {
            dismissedAnchor = nil
            close()
            return
        }
        if let dismissedAnchor {
            guard dismissedAnchor != query.anchor else { return }
            self.dismissedAnchor = nil
        }
        let items = provider.completions(for: query)
        guard !items.isEmpty else {
            close()
            return
        }
        // 絞り込みの途中では、選んでいた候補が残っていればそれを選んだまま
        let selected = session.flatMap { previous in items.firstIndex(of: previous.selectedItem) } ?? 0
        session = Session(query: query, items: items, selectedIndex: selected)
    }

    /// キャレットが打鍵以外で動いた(矢印、クリック、プログラムからの選択): 一覧は閉じる。Esc の記憶は、きっかけの外へ出たら消す。
    func caretDidMove(text: NSString, caret: NSRange, plan: HighlightPlan) {
        close()
        guard let dismissedAnchor else { return }
        if caret.length > 0 || CompletionTrigger.detect(text: text, caret: caret.location, plan: plan)?.anchor != dismissedAnchor {
            self.dismissedAnchor = nil
        }
    }

    /// 本文が打鍵以外で変わった(ペースト、Undo、プログラムからの置換): 一覧は閉じる。
    func textDidChangeOutsideTyping() {
        close()
    }

    func close() {
        session = nil
    }

    /// Esc: 閉じて、同じきっかけでは開き直さない。
    func dismiss() {
        dismissedAnchor = session?.query.anchor
        close()
    }

    func moveSelection(by delta: Int) {
        guard var session else { return }
        let count = session.items.count
        session.selectedIndex = ((session.selectedIndex + delta) % count + count) % count
        self.session = session
    }

    func select(index: Int) {
        guard var session, session.items.indices.contains(index) else { return }
        session.selectedIndex = index
        self.session = session
    }

    /// 確定の編集(閉じもする)。一覧が無ければ nil。
    func commitCommand(for item: CompletionItem? = nil, in text: NSString) -> EditCommand? {
        guard let session else { return nil }
        let chosen = item ?? session.selectedItem
        close()
        return CompletionTrigger.command(for: session.query, item: chosen, in: text)
    }

    /// 一覧が開いているときのキー。移動と確定は修飾キー無しだけ(Shift+Tab はアウトデント、Shift+↑↓ は選択のまま)。
    /// 修飾キー付きとキャレットを動かすキーは一覧を閉じて流す。文字・削除のキーは nil(打鍵として届き、`noteTyping` が判定する)。
    func keyAction(for input: KeyInput) -> CompletionKeyAction? {
        guard session != nil else { return nil }
        let plain = input.modifiers.isEmpty
        switch input.key {
        case .up where plain: return .moveUp
        case .down where plain: return .moveDown
        case .return where plain, .tab where plain: return .commit
        case .escape where plain: return .dismiss
        case .left, .right, .home, .end, .pageUp, .pageDown, .up, .down, .return, .tab, .escape: return .closeAndPassThrough
        case .character where !input.modifiers.subtracting([.shift, .option]).isEmpty: return .closeAndPassThrough
        case .character, .backspace, .forwardDelete: return nil
        }
    }

    private func publish() {
        listState?.publish(owner: self, items: session?.items ?? [], selectedIndex: session?.selectedIndex ?? 0)
    }

    isolated deinit {
        listState?.unregister(owner: self)
    }
}
