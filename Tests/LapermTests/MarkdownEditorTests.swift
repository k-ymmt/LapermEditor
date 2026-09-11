#if os(macOS)
import Testing
@testable import Laperm

@Test func moduleLoads() {
    // Laperm が LapermCore を再エクスポートしていること
    let kind: SyntaxKind = .strong
    #expect(kind == .strong)
}
#endif
