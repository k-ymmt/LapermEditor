/// 編集支援機能の個別 ON/OFF 設定。デフォルトは全機能有効。
public struct EditingOptions: Equatable, Sendable {
    /// Enter でリスト項目を自動継続する(空項目では脱出)
    public var continuesLists: Bool
    /// チェックボックスのクリックでチェック状態を切り替える
    public var togglesCheckboxOnClick: Bool
    /// Tab / Shift+Tab でリスト項目のネストレベルを上げ下げする
    public var indentsListItems: Bool
    /// 選択範囲の囲い込みと括弧系・バッククォートの自動閉じ
    public var completesPairs: Bool
    /// テキスト選択中に URL をペーストしたら [選択](URL) へ変換する
    public var linkifiesPastedURL: Bool

    public init(
        continuesLists: Bool = true,
        togglesCheckboxOnClick: Bool = true,
        indentsListItems: Bool = true,
        completesPairs: Bool = true,
        linkifiesPastedURL: Bool = true
    ) {
        self.continuesLists = continuesLists
        self.togglesCheckboxOnClick = togglesCheckboxOnClick
        self.indentsListItems = indentsListItems
        self.completesPairs = completesPairs
        self.linkifiesPastedURL = linkifiesPastedURL
    }
}
