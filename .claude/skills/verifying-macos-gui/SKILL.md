---
name: verifying-macos-gui
description: Use when verifying macOS app behavior end-to-end via computer use — launching the built app, synthesizing keyboard/mouse input, and confirming results on screen. Applies to GUI smoke tests of the Example app (Vim mode, cursor rendering, IME interaction, editing assistance) or any change unit tests cannot observe visually.
---

# Verifying macOS GUI via Computer Use

Drive the real app with synthesized keystrokes and verify with screenshots. **Screenshots are the oracle; accessibility (AX) queries are not** — for SwiftUI apps, System Events AX lookups fail intermittently (`Invalid index (-1719)`, `Can't make «class valL» into type string (-1700)`, `count of windows` returning 0 while the window is visibly on screen). Do not build assertions on AX element reads.

## The Loop

1. **Build & locate**: `xcodebuild -project Example/Example.xcodeproj -scheme ExampleMacOS build`, then find the app under `~/Library/Developer/Xcode/DerivedData/Example-*/Build/Products/Debug/`.
2. **Neutralize the IME** (do this FIRST): save the current input source ID, switch to ABC. With Japanese input active, `keystroke "abc"` becomes marked text 「あbc」 and every assertion breaks.
   ```bash
   swift .claude/skills/verifying-macos-gui/scripts/switch-input-source.swift            # prints current ID — save it
   swift .claude/skills/verifying-macos-gui/scripts/switch-input-source.swift com.apple.keylayout.ABC
   ```
3. **Launch & focus**: `open <app>`, then before EVERY keystroke batch: `tell application "ExampleMacOS" to activate` — System Events types into the frontmost app, whatever it is. **The terminal steals focus back between separate tool calls**, so chain `activate` + keystrokes + `screencapture` inside ONE shell invocation, and before risky actions assert `first application process whose frontmost is true` is the target app.
4. **Drive**: `keystroke "x"` / `key code 53` (Esc). Insert `delay 0.2`–`0.5` between steps; keystrokes race the UI without them.
5. **Verify**: screenshot a region and Read the image:
   ```bash
   # window bounds (screen coordinates) — the one AX call that is reliable enough; on error, retry once, then full-screen capture
   osascript -e 'tell application "System Events" to tell process "ExampleMacOS" to get {position, size} of window 1'
   screencapture -x -R215,156,1067,655 step1.png   # -R<x>,<y>,<w>,<h>
   ```
   Crop tighter regions (e.g. the status bar, the edited lines) for cheap before/after comparisons.
6. **Clean up** (always, even on failure): undo test edits (`keystroke "z" using command down`), quit the app, restore the saved input source with the same script.

## Common Mistakes

| Mistake | Reality |
|---|---|
| Reading text via AX (`text area of scroll area`, `entire contents`) | Flaky for SwiftUI; errors even inside `try`. Verify pixels instead. |
| Skipping the IME switch | Keystrokes get composed as marked text; deletions/moves may still work (bypasses IME by design in some apps) but insertions won't be literal. |
| `click at {x, y}` with window-relative coordinates | Coordinates are SCREEN-absolute. Offset by the window's `position`. |
| AppleScript variable named `before`, `end`, `result` | Reserved words → confusing syntax errors. Use `txtA`, `txtB`. |
| One giant osascript doing everything | One failure loses all progress. Small script → screenshot → Read → next. |
| Leaving state behind | Restore input source, undo document edits, quit the app — the user's machine is not a scratchpad. |
| Separate tool calls for activate → type → capture | The terminal regains frontmost between calls; keystrokes silently hit the wrong window. Chain them in one invocation. |
| Concluding "cursor doesn't render" from a cropped shot | The caret may be scrolled outside the viewport. Take a full-window screenshot (and scroll the caret into view) before judging rendering. |

Esc is `key code 53` (it has no `keystroke` form). Modifier example: `keystroke "z" using command down`.
