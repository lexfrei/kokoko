# Drag diagnostics

## Native hit-target check

On macOS, the debug executable can check the actual drag handle inside a hidden selectable List:

```bash
swift run kokoko-mac --check-drag-hit-target
```

This mode exits before normal app startup, window activation, device watching or scanning. It creates no input events and never shows its test windows. It checks empty, single and multiple selection, the handle's hit region, and a point outside that region. The mode is compiled only in debug builds; use the command above, not a Release app with this argument.

A passing check establishes hit-target ownership, not real dragging, slot swapping or Finder export.

## Log a manual drag

Drag logging is off by default. Set `KOKOKO_DRAG_DIAGNOSTICS=1` when starting a test app's executable. Replace the app path below with the artifact being tested; close another running copy first so the intended process receives the gesture.

```bash
APP="/path/to/kokoko.app"
LOG="$(mktemp "$HOME/Downloads/kokoko-drag.XXXXXX")"
printf 'Log: %s\n' "$LOG"
KOKOKO_DRAG_DIAGNOSTICS=1 "$APP/Contents/MacOS/kokoko" 2> "$LOG"
```

Perform the gesture manually, then quit the app normally. Launching the app normally without the environment variable leaves drag logging off. No system-wide event monitor is installed.

Records prefixed with `kokoko drag` include source-view identity, mouse-down/drag/up delivery, guard refusals, native session begin/end, target validation, text-provider completion and swap-confirmation requests. Promise-writing records distinguish export from internal movement. The iOS file-provider path also records whether its main-actor task was entered; logging does not change that path's scheduling.

The drag records omit filenames, sound names, nonce values and raw payloads. Errors include only domain/code, not localized descriptions. Other framework output may also appear on standard error; inspect a log before sharing it.

Use the stages to distinguish failures:

- No `source down`: the handle did not record the mouse-down; compare its hit region and the pointer location.
- `source down` followed by a different source identity or `reject=no-down`: inspect view lifetime and event routing.
- `source dragged` followed by a guard refusal: inspect that guard before changing payloads.
- `source session-begin` with no `target perform`: initiation worked; investigate the destination or cancellation.
- `target text-complete` followed by a rejection: inspect provider errors or the context check. No raw text needs to be logged.
- A swap request without a visible confirmation, or a promise request without completion, is a later UI/export stage; it is not evidence that List selection intercepted the initial gesture.

These are diagnostic boundaries, not a guarantee that every failure emits a record. Actual horizontal/vertical dragging, ordinary row selection, cancelled sessions and Finder copying still require a manual test.
