//
//  ContentView.swift
//  ExampleMacOS
//
//  Created by Kazuki Yamamoto on 2026/07/14.
//

import AppKit
import Laperm
import SwiftUI

struct ContentView: View {
    @State private var text = ContentView.sampleDocument
    @State private var showsLineNumbers = true
    @State private var useAlternateTheme = false
    @State private var vim = VimController()

    var body: some View {
        MarkdownEditorView(text: $text, theme: useAlternateTheme ? Self.alternateTheme : .default)
            .showsLineNumbers(showsLineNumbers)
            .inputInterceptor(vim.isEnabled ? vim : nil)
            .insertionPointStyle(vim.insertionPointStyle)
            .frame(minWidth: 640, minHeight: 480)
            .toolbar {
                ToolbarItem {
                    Toggle("行番号", isOn: $showsLineNumbers)
                }
                ToolbarItem {
                    Toggle("テーマ", isOn: $useAlternateTheme)
                }
                ToolbarItem {
                    Toggle("Vim", isOn: $vim.isEnabled)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let status = vim.statusText {
                    Text(status)
                        .font(.system(.caption, design: .monospaced).bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.bar)
                }
            }
    }

    static let alternateTheme: MarkdownTheme = {
        var theme = MarkdownTheme.default
        theme.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        for level in 1...6 {
            var style = theme.styles[.heading(level: level)] ?? .init()
            style.foregroundColor = .systemTeal
            theme.styles[.heading(level: level)] = style
        }
        var code = theme.styles[.inlineCode] ?? .init()
        code.foregroundColor = .systemGreen
        theme.styles[.inlineCode] = code
        return theme
    }()

    static let sampleDocument = """
    # Laperm デモ

    TextKit2 をフル活用した **シンタックスハイライト型** エディタです。\
    *イタリック* や `インラインコード` も装飾されます。

    ## コードブロック

    ```swift
    let editor = MarkdownTextView()
    editor.string = "# Hello"
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

    - リスト行末で Enter → 次項目を自動継続(空項目で Enter すると脱出)
    - [ ] このチェックボックスはクリックでトグルできます
    - Tab / Shift+Tab でネスト変更、テキストを選択して `*` などを入力すると囲い込み
    - ツールバーの Vim トグルで簡易 Vim モード(hjkl / w b / 0 $ / x dd / i a o O / Esc)

    日本語も絵文字 🎉 も正しくハイライトされます。
    """
}

#Preview {
    ContentView()
}
