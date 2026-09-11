#if os(macOS)
import AppKit
import Testing
@testable import Laperm
@testable import LapermCore

@MainActor
private final class RecordingInterceptor: TextInputInterceptor {
    var received: [KeyInput] = []
    var result: KeyInputResult = .passthrough
    func textView(_ textView: MarkdownTextView, handle input: KeyInput) -> KeyInputResult {
        received.append(input)
        return result
    }
}

@MainActor @Test func handledResultConsumesKeyDown() {
    let textView = MarkdownTextView()
    let interceptor = RecordingInterceptor()
    interceptor.result = .handled
    textView.inputInterceptor = interceptor
    textView.keyDown(with: keyEvent("a"))
    #expect(textView.string == "")  // 挿入されない
    #expect(interceptor.received == [KeyInput(key: .character("a"))])
}

@MainActor @Test func passthroughDoesNotIntercept() {
    let textView = MarkdownTextView()
    let interceptor = RecordingInterceptor()
    interceptor.result = .passthrough
    textView.inputInterceptor = interceptor
    #expect(!textView.interceptsKeyDown(keyEvent("a")))
    #expect(interceptor.received.count == 1)  // 呼ばれた上で通過
}

@MainActor @Test func noInterceptorMeansNoInterception() {
    let textView = MarkdownTextView()
    #expect(!textView.interceptsKeyDown(keyEvent("a")))
}

@MainActor @Test func markedTextBypassesInterceptor() {
    let textView = MarkdownTextView()
    let interceptor = RecordingInterceptor()
    interceptor.result = .handled
    textView.inputInterceptor = interceptor
    textView.setMarkedText(
        "か", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!textView.interceptsKeyDown(keyEvent("a")))
    #expect(interceptor.received.isEmpty)  // IME 変換中は呼ばれない
}

@MainActor @Test func interceptorIsHeldWeakly() {
    let textView = MarkdownTextView()
    var interceptor: RecordingInterceptor? = RecordingInterceptor()
    textView.inputInterceptor = interceptor
    interceptor = nil
    #expect(textView.inputInterceptor == nil)
}
#endif
