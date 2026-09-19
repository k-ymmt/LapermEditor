#if os(macOS)
import Testing
@testable import LapermEditor

@Test func moduleLoads() {
    // Laperm が LapermCore を再エクスポートしていること
    let kind: SyntaxKind = .strong
    #expect(kind == .strong)
}
#endif
