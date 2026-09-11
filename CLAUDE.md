# Laperm

TextKit2-based Markdown editor library for macOS (Swift 6, macOS 27+).

## Platforms

- `LapermCore` (parser / highlight model, Foundation-only) supports macOS 27+ and iOS 27+.
- `Laperm` (AppKit UI layer) is macOS-only. Its sources and `LapermTests` are wrapped in `#if os(macOS)` so the package as a whole resolves and builds on iOS; a UIKit port has not been started.
- Verify `LapermCore` on iOS with:
  `xcodebuild test -scheme Laperm-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -only-testing:LapermCoreTests`

## Verification

- **macOS GUI verification MUST use computer use**: launch the real app, drive it with synthesized keyboard/mouse input, and confirm results with screenshots. Follow the project skill `verifying-macos-gui` (`.claude/skills/verifying-macos-gui/SKILL.md`). Unit tests and a successful build alone do NOT count as end-to-end verification for user-visible behavior.
