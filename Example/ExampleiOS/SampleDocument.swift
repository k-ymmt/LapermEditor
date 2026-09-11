enum SampleDocument {
    static let markdown = """
    # Laperm デモ

    TextKit2 をフル活用した **シンタックスハイライト型** エディタです。\
    *イタリック* や `インラインコード` も装飾されます。

    ## コードブロック

    ```swift
    let editor = MarkdownTextView()
    editor.text = "# Hello"
    ```

    > 引用は縦バー付きで表示されます。
    > > ネストも可能。

    - リスト項目 1
    - リスト項目 2 と [リンク](https://example.com)

    1. 番号付きリスト

    ---

    ## GFM 拡張

    ~~打ち消し線~~ が使えます。

    - [x] 完了したタスク
    - [ ] 未完了のタスク

    | 構文 | 対応 |
    |------|------|
    | テーブル | あり |
    | `インラインコード` | あり |

    ## 編集支援

    - リスト行末で Return → 次項目を自動継続(空項目で Return すると脱出)
    - [ ] このチェックボックスはタップでトグルできます
    - Tab / Shift+Tab でネスト変更、テキストを選択して `*` などを入力すると囲い込み
    - ガター左端の ▼ をタップするとセクションを折りたたみ

    日本語も絵文字 🎉 も正しくハイライトされます。

    ## リンク

    - [インラインリンク](https://example.com/inline) にキャレットを置いてタップ → 「リンクを開く」
    - 参照リンク: [Laperm リポジトリ][repo]
    - ベア URL: https://example.com/bare も開けます
    - 相対パス: [サンプル画像を開く](sample.png)
    - 選択して URL をペーストするとリンク化されます

    [repo]: https://example.com/repo

    ## 画像

    ローカル画像(表示される):

    ![サンプル](sample.png)

    存在しないパス(エラー枠):

    ![見つからない画像](missing.png)

    リモート画像(デフォルト不許可 → エラー枠):

    ![リモート](https://example.com/remote.png)
    """

    /// UI テスト用の小さな文書(行位置が予測しやすいよう短くしてある)
    static let uiTest = """
    # 見出し
    - [ ] タスク

    本文 **強調** `code`
    [インラインリンク](https://example.com/inline)
    > 引用

    ## 次の見出し
    末尾
    """
}
