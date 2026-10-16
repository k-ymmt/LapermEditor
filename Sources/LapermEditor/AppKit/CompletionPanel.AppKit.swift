#if os(macOS)
import AppKit
import LapermCore

/// Completion List のパネル(macOS、Laperm ADR 0047): キャレットの直下(下に余地が無ければ上)に出る、OS 標準の見た目の角丸の
/// パネル(システムフォント、選択行はアクセントカラー、Theme の色は使わない)。見える行数は最大 8、それ以上はスクロール。
/// 幅は内容に合わせ、最小 240 pt。キーを取らない(`canBecomeKey` は false: テキストビューがフォーカスを持ったまま打ち続ける)
/// 子ウィンドウとしてテキストビューのウィンドウに付く。クリックで確定(`onSelect`)。
@MainActor
final class CompletionPanel: NSPanel {
    static let rowHeight: CGFloat = 24
    static let maximumVisibleRows = 8
    static let minimumWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 560
    static let contentPadding: CGFloat = 4
    static let cornerRadius: CGFloat = 8
    /// キャレットとパネルの隙間。
    static let caretGap: CGFloat = 2

    private let tableView = CompletionTableView()
    private let scrollView = NSScrollView()
    private let dataSource = CompletionTableDataSource()
    private(set) var items: [CompletionItem] = []
    var onSelect: ((Int) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        contentView = background

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.setAccessibilityIdentifier("CompletionList")
        tableView.setAccessibilityLabel(String(localized: "Completions", bundle: .module))
        tableView.onRowClick = { [weak self] row in self?.onSelect?(row) }
        dataSource.panel = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: Self.contentPadding, left: 0, bottom: Self.contentPadding, right: 0)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = background.bounds
        background.addSubview(scrollView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 一覧を見せる(または更新する)。`anchorRect` はスクリーン座標のキャレットの矩形(文字の左端にパネルの文字を揃える)。
    func present(items: [CompletionItem], selectedIndex: Int, anchorRect: NSRect, parent: NSWindow) {
        self.items = items
        tableView.reloadData()
        let size = Self.size(for: items)
        let frame = Self.frame(size: size, anchorRect: anchorRect, visibleFrame: (parent.screen ?? NSScreen.main)?.visibleFrame)
        setFrame(frame, display: false)
        select(selectedIndex)
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        if !isVisible { orderFront(nil) }
    }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        items = []
        tableView.reloadData()
    }

    var selectedRow: Int { tableView.selectedRow }

    /// 内容の幅(最小 240、最大 560)と、見える行数(最大 8)の高さ。
    static func size(for items: [CompletionItem]) -> NSSize {
        var width: CGFloat = 0
        for item in items {
            width = max(width, CompletionCellView.preferredWidth(for: item))
        }
        let rows = min(items.count, maximumVisibleRows)
        return NSSize(
            width: min(maximumWidth, max(minimumWidth, ceil(width))),
            height: CGFloat(rows) * rowHeight + 2 * contentPadding)
    }

    /// キャレットの直下に、文字の左端(パネルの文字の余白の分だけ左)に揃えて。下に余地が無ければ上。横は画面の中に収める。
    static func frame(size: NSSize, anchorRect: NSRect, visibleFrame: NSRect?) -> NSRect {
        var x = anchorRect.minX - CompletionCellView.horizontalInset
        var y = anchorRect.minY - caretGap - size.height
        if let visible = visibleFrame {
            if y < visible.minY { y = anchorRect.maxY + caretGap }
            if y + size.height > visible.maxY { y = max(visible.minY, visible.maxY - size.height) }
            x = max(visible.minX, min(x, visible.maxX - size.width))
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// パネルの表の中身。
@MainActor
private final class CompletionTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var panel: CompletionPanel?

    func numberOfRows(in tableView: NSTableView) -> Int { panel?.items.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = panel?.items[row] else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CompletionCellView ?? {
            let cell = CompletionCellView()
            cell.identifier = identifier
            return cell
        }()
        cell.configure(with: item)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }

    /// 選択はキー操作とクリック(パネル)が決める: 表のクリックは `mouseDown` で確定に変える
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}

/// クリックで確定する表(選択の切り替えにはしない)。キーウィンドウでなくても最初のクリックを受ける。
@MainActor
private final class CompletionTableView: NSTableView {
    var onRowClick: ((Int) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        onRowClick?(row)
    }
}

/// 選択行: アクセントカラーの角丸(キーウィンドウでなくても同じ見た目)。
@MainActor
private final class CompletionRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            for case let cell as CompletionCellView in subviews { cell.isHighlighted = isSelected }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: CompletionPanel.contentPadding, dy: 0)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

/// 1 行: タイトルを主、副文字(フォルダのパス、`H2`)を右に。
@MainActor
final class CompletionCellView: NSTableCellView {
    static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let detailFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// 文字の左右の余白(パネルの左端はキャレットの左端からこの分だけ左)。
    static let horizontalInset: CGFloat = 12
    static let gap: CGFloat = 8

    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    var isHighlighted = false {
        didSet { updateColors() }
    }

    init() {
        super.init(frame: .zero)
        titleField.font = Self.titleFont
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityIdentifier("CompletionTitle")
        detailField.font = Self.detailFont
        detailField.lineBreakMode = .byTruncatingMiddle
        detailField.setAccessibilityIdentifier("CompletionDetail")
        addSubview(titleField)
        addSubview(detailField)
        textField = titleField
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: CompletionItem) {
        titleField.stringValue = item.title
        detailField.stringValue = item.detail ?? ""
        detailField.isHidden = (item.detail ?? "").isEmpty
        setAccessibilityLabel(item.detail.map { $0.isEmpty ? item.title : "\(item.title) — \($0)" } ?? item.title)
        needsLayout = true
    }

    private func updateColors() {
        titleField.textColor = isHighlighted ? .alternateSelectedControlTextColor : .labelColor
        detailField.textColor = isHighlighted ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        let inset = Self.horizontalInset
        let available = max(0, bounds.width - 2 * inset)
        let titleSize = titleField.intrinsicContentSize
        let detailSize = detailField.isHidden ? .zero : detailField.intrinsicContentSize
        // タイトルを優先し、副文字は残りに収める(長いパスは中を省く)
        var titleWidth = min(titleSize.width, available)
        var detailWidth: CGFloat = 0
        if !detailField.isHidden {
            detailWidth = min(detailSize.width, max(0, available - titleWidth - Self.gap))
            if detailWidth < 40, available > 120 {
                detailWidth = min(detailSize.width, available * 0.4)
                titleWidth = min(titleSize.width, available - detailWidth - Self.gap)
            }
        }
        titleField.frame = NSRect(x: inset, y: (bounds.height - titleSize.height) / 2, width: titleWidth, height: titleSize.height)
        if !detailField.isHidden {
            detailField.frame = NSRect(
                x: inset + titleWidth + Self.gap, y: (bounds.height - detailSize.height) / 2, width: detailWidth, height: detailSize.height)
        }
    }

    /// この行に要る幅(余白込み)。
    static func preferredWidth(for item: CompletionItem) -> CGFloat {
        var width = 2 * horizontalInset + (item.title as NSString).size(withAttributes: [.font: titleFont]).width
        if let detail = item.detail, !detail.isEmpty {
            width += gap + (detail as NSString).size(withAttributes: [.font: detailFont]).width
        }
        return width
    }
}
#endif
