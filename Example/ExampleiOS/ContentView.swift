import LapermEditor
import SwiftUI
import UIKit

/// iOS 版デモ。macOS 版(ExampleMacOS)と同じサンプル文書で、
/// 行番号・テーマ切替・アウトライン・開いたリンクの表示を確認できる。
/// (Vim モードとカーソル形状は macOS 専用 API のため iOS 版にはない)
struct ContentView: View {
    @State private var text = ProcessInfo.processInfo.arguments.contains("-uiTestDocument")
        ? SampleDocument.uiTest : SampleDocument.markdown
    @State private var showsLineNumbers = true
    @State private var useAlternateTheme = false
    @State private var livePreview = ProcessInfo.processInfo.arguments.contains("-livePreview")
    @State private var outline: [OutlineItem] = []
    @State private var editorProxy = MarkdownEditorProxy()
    @State private var lastOpenedURL: URL?
    @State private var showsOutline = false
    private let imageDirectory = makeSampleImageDirectory()

    var body: some View {
        NavigationStack {
            MarkdownEditorView(
                text: $text, theme: useAlternateTheme ? Self.alternateTheme : .default
            )
            .showsLineNumbers(showsLineNumbers)
            .livePreviewEnabled(livePreview)
            .imagePreviewOptions(.init(baseURL: imageDirectory))
            .linkOptions(.init(baseURL: imageDirectory))
            .onOpenLink { url in
                lastOpenedURL = url
                // デモではブラウザを起動せずステータスバーに表示するだけ
                return true
            }
            .onOutlineChange { outline = $0 }
            .editorProxy(editorProxy)
            .ignoresSafeArea(.keyboard)
            .navigationTitle("Laperm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("アウトライン", systemImage: "list.bullet") {
                        showsOutline = true
                    }
                    .accessibilityIdentifier("outlineButton")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Toggle("行番号", systemImage: "list.number", isOn: $showsLineNumbers)
                        .accessibilityIdentifier("lineNumbersToggle")
                    Toggle("テーマ", systemImage: "paintpalette", isOn: $useAlternateTheme)
                        .accessibilityIdentifier("themeToggle")
                    Toggle("Live Preview", systemImage: "eye", isOn: $livePreview)
                        .accessibilityIdentifier("livePreviewToggle")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let url = lastOpenedURL {
                    Text("開いたリンク: \(url.absoluteString)")
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.bar)
                        .accessibilityIdentifier("openedLinkStatus")
                }
            }
            .sheet(isPresented: $showsOutline) {
                NavigationStack {
                    List(outline, id: \.headingLocation) { item in
                        Button {
                            showsOutline = false
                            editorProxy.scrollToHeading(at: item.headingLocation)
                        } label: {
                            Text(item.title)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(item.level - 1) * 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .navigationTitle("アウトライン")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    static let alternateTheme: MarkdownTheme = {
        var theme = MarkdownTheme.default
        theme.backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        theme.bodyColor = .white
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
}

/// Example 用のサンプル画像(単色 PNG)を一時ディレクトリに生成して、
/// そのディレクトリを imagePreviewOptions.baseURL として使う。
func makeSampleImageDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LapermExampleImages", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("sample.png")
    if !FileManager.default.fileExists(atPath: file.path) {
        let size = CGSize(width: 320, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setStroke()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 320, y: 180))
            path.move(to: CGPoint(x: 320, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 180))
            path.lineWidth = 4
            path.stroke()
        }
        try? image.pngData()?.write(to: file)
    }
    return directory
}
