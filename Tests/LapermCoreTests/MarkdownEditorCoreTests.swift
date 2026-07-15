import Testing
@testable import LapermCore

@Test func syntaxKindIsHashable() {
    let set: Set<SyntaxKind> = [.heading(level: 1), .heading(level: 1), .strong]
    #expect(set.count == 2)
}
