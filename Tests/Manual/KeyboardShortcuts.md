# Keyboard shortcut regression checks

Run these checks on a fresh launch after changing command/focus handling. Start a separate preview app if the main app has active connections or editor sessions. Use unsaved profiles pointing at `127.0.0.1`, port `1`, with no credentials; successful network authentication is not required. Do not save the profiles or credentials.

## Command-W before opening the File menu

1. Launch the app with no tabs. **Do not open the File menu.**
2. Add an unsaved connection using the welcome-screen/toolbar button.
3. Press **⌘W** immediately after its panels appear.
4. Expect the connection tab to disappear and the same window to show the welcome screen.

This reproduces the original failure: ⌘W did nothing until the File menu was opened, although clicking Close Tab in that menu worked. The commands previously received an unobserved focused value and retained stale shortcut enablement. `focusedSceneObject` / `FocusedObject` now observe the workspace's published tab state.

## Multiple tabs and focus changes

1. Add two unsaved connections with distinct names.
2. Focus a path/filter text field in the active tab.
3. Press **⌘W** without opening File. Expect only the active tab to close and the neighboring tab to become active.
4. Focus a file outline or the sidebar, then press **⌘W** again. Expect the remaining tab to close and the window to remain open.
5. Press **⌘W** on the welcome screen. Expect no action; there is no tab to close.
6. Add another tab and repeat to check that the shortcut is enabled again.

## Explicit window closing

Press **⇧⌘W**. Expect the entire window to close. It must remain distinct from the tab-closing shortcut.

The automated `WorkspaceTests` cover selected-tab removal and neighbor selection. These manual checks cover native SwiftUI menu/shortcut invalidation, which those model tests do not exercise. See [VALIDATION.md](../../VALIDATION.md) for recorded runs.
