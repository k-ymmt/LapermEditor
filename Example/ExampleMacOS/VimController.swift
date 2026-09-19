import AppKit
import LapermEditor
import Observation

/// VimEngine と MarkdownTextView をつなぐインターセプタ。
/// MarkdownTextView 側は weak 保持のため、ContentView が @State で所有する。
@Observable @MainActor
final class VimController: TextInputInterceptor {
    var isEnabled = false {
        didSet {
            guard !isEnabled else { return }
            engine = VimEngine()  // OFF で normal に戻す
            mode = engine.mode
        }
    }
    private(set) var mode: VimEngine.Mode = .normal
    @ObservationIgnored private var engine = VimEngine()

    var insertionPointStyle: InsertionPointStyle {
        isEnabled && mode == .normal ? .block : .bar
    }

    var statusText: String? {
        guard isEnabled else { return nil }
        return mode == .normal ? "NORMAL" : "INSERT"
    }

    func textView(_ textView: MarkdownTextView, handle input: KeyInput) -> KeyInputResult {
        guard isEnabled else { return .passthrough }
        let action = engine.handle(
            input, text: textView.string as NSString, selection: textView.selectedRange())
        mode = engine.mode
        switch action {
        case .passthrough:
            return .passthrough
        case .none:
            return .handled
        case .move(let offset):
            let range = NSRange(location: offset, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            return .handled
        case .edit(let command):
            textView.perform(command)
            textView.scrollRangeToVisible(textView.selectedRange())
            return .handled
        }
    }
}
