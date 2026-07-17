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
    @State private var outline: [OutlineItem] = []
    @State private var editorProxy = MarkdownEditorProxy()
    @State private var lastOpenedURL: URL?
    private let imageDirectory = makeSampleImageDirectory()

    var body: some View {
        NavigationSplitView {
            List(outline, id: \.headingLocation) { item in
                Button {
                    editorProxy.scrollToHeading(at: item.headingLocation)
                } label: {
                    Text(item.title)
                        .lineLimit(1)
                        .padding(.leading, CGFloat(item.level - 1) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 200)
        } detail: {
            MarkdownEditorView(
                text: $text, theme: useAlternateTheme ? Self.alternateTheme : .default
            )
            .showsLineNumbers(showsLineNumbers)
            .inputInterceptor(vim.isEnabled ? vim : nil)
            .insertionPointStyle(vim.insertionPointStyle)
            .imagePreviewOptions(.init(baseURL: imageDirectory))
            .linkOptions(.init(baseURL: imageDirectory))
            .onOpenLink { url in
                lastOpenedURL = url
                // デモではブラウザを起動せずステータスバーに表示するだけ
                return true
            }
            .onOutlineChange { outline = $0 }
            .editorProxy(editorProxy)
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

    ## リンク

    - [インラインリンク](https://example.com/inline) を Cmd+クリック
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
}

/// Example 用のサンプル画像(単色 PNG)を一時ディレクトリに生成して、
/// そのディレクトリを imagePreviewOptions.baseURL として使う。
/// ContentView の stored property 初期化子(非分離コンテキスト)から呼ぶため
/// @MainActor は付けない(オフスクリーン描画のみでビュー階層に触れない)。
func makeSampleImageDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LapermExampleImages", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("sample.png")
    if !FileManager.default.fileExists(atPath: file.path) {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: 320, y: 180))
        path.move(to: NSPoint(x: 320, y: 0))
        path.line(to: NSPoint(x: 0, y: 180))
        path.lineWidth = 4
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }
    return directory
}
