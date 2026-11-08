# Drag diagnostics

## Native hit-target check

On macOS, the debug executable can check the actual drag handle inside a hidden selectable List:

```bash
swift run kokoko-mac --check-drag-hit-target
```

This mode exits before normal app startup, window activation, device watching or scanning. It creates no input events and never shows its test windows. It checks empty, single and multiple selection, the handle's hit region, and a point outside that region. The mode is compiled only in debug builds; use the command above, not a Release app with this argument.

A passing check establishes hit-target ownership, not real dragging, slot swapping or Finder export.

## Native pasteboard and row-containment checks

The macOS row destination reads the existing UTF-8 token directly from the native dragging pasteboard. The private marker and token must belong to the same single pasteboard item. The native drag handle and its WAV file promise remain the source; iOS keeps its SwiftUI item-provider destination.

The debug executable provides two checks:

```bash
swift run kokoko-mac --check-drag-provider
swift run kokoko-mac --check-native-row-drop
```

The first writes the actual RowPromise to a unique named pasteboard and checks its local representations without fulfilling the WAV promise. It does not exercise SwiftUI's pasteboard-to-item-provider bridge.

The second sends that writer's native pasteboard through the destination's receive methods and checks authentication, rejected item combinations, one-time claiming, operation masks, terminal cleanup, generation and busy guards. Its callback fixture implements NSDraggingInfo without creating an OS dragging session. Hidden-window checks use the real sound rows to compare native containment with the SwiftUI destination: selection, hit regions, editor bindings, inherited environment and variable row height. The normal macOS route is used without a native-destination opt-in.

Both modes exit before activation, device watching or scanning, use no general pasteboard or hardware, and synthesize no OS input. Programmatic focus and callback checks do not establish keyboard event delivery, actual dragging or Finder export; those still need a manual session.

## Log a manual drag

Drag logging is off by default. Set `KOKOKO_DRAG_DIAGNOSTICS=1` when starting a test app's executable. Replace the app path below with the artifact being tested; close another running copy first so the intended process receives the gesture.

```bash
APP="/path/to/kokoko.app"
LOG="$(mktemp "$HOME/Downloads/kokoko-drag.XXXXXX")"
printf 'Log: %s\n' "$LOG"
KOKOKO_DRAG_DIAGNOSTICS=1 "$APP/Contents/MacOS/kokoko" 2> "$LOG"
```

Perform the gesture manually, then quit the app normally. Launching the app normally without the environment variable leaves drag logging off. No system-wide event monitor is installed.

Records prefixed with `kokoko drag` include source-view identity, mouse-down/drag/up delivery, guard refusals and native session begin/end. The macOS destination uses `native target` stages for entry, performance, pasteboard item types, token byte count/match and swap-confirmation requests. The SwiftUI destination uses `swiftui target` stages for validation and asynchronous provider completion. Promise-writing records distinguish export from internal movement. The iOS file-provider path also records whether its main-actor task was entered; logging does not change that path's scheduling.

The drag records omit filenames, sound names, nonce values and raw payloads. Errors include only domain/code, not localized descriptions. Other framework output may also appear on standard error; inspect a log before sharing it.

Use the stages to distinguish failures:

- No `source down`: the handle did not record the mouse-down; compare its hit region and the pointer location.
- `source down` followed by a different source identity or `reject=no-down`: inspect view lifetime and event routing.
- `source dragged` followed by a guard refusal: inspect that guard before changing payloads.
- `source session-begin` with no `native target perform` on macOS: initiation reached the native session; investigate the destination or cancellation.
- `native target reject=pasteboard-shape`: the native board did not contain the required single marked item.
- `native target reject=text-unavailable`: the exact native UTF-8 representation could not be read or decoded.
- `native target text` followed by `reject=authentication-or-state-change`: inspect the match result and context guards, not a different text type.
- `swiftui target text-complete` followed by a rejection: inspect provider errors or the context check. This is the iOS destination or the comparison path used by the debug check, not the normal macOS destination.
- A swap request without a visible confirmation, or a promise request without completion, is a later UI/export stage; it is not evidence that List selection intercepted the initial gesture.

These are diagnostic boundaries, not a guarantee that every failure emits a record. Actual horizontal/vertical dragging, ordinary row selection, cancelled sessions and Finder copying still require a manual test.
