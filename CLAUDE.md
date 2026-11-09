# kokoko development principles

## UI style

- Use monospaced text and short bracketed controls. Avoid decorative ASCII frames and terminal imitation. Waveforms are drawn graphics styled to match the text interface, not ASCII art.
- Render literal ASCII controls and markers with `Text(verbatim:)` so Markdown does not consume characters or change their width.
- Keep geometry stable: selecting a tab must not change its width. Opening an overlay or menu must not resize the main content or shift its scroll position. Inline expansion may add space below its row, but must preserve column alignment.

## Editing and overlays

- Prefer editing directly in the row when the task fits there, such as renaming a sound or changing its slot number. Do not open a popup for a simple field that can be edited in place.
- Use a nonmodal overlay inside the window for editors with many parameters. Inline editing and overlays are complementary choices, not interchangeable defaults.
- Anchor an overlay near the invoking control. For keyboard invocation, use the selected object or focused control. Keep the anchor fixed while the overlay is open; choose the other side near an edge and keep the panel inside the window.
- Do not add a pane to `HSplitView` or use a large sheet for routine editing. Destructive confirmations must match the application's style and clearly state the operation.

## Menus

- Custom dropdowns and context menus share an opaque surface, monospaced typography, and consistent navigation. Do not pair an ASCII control with a system glass dropdown.
- Keep system title bars, menu bars, Settings windows, file panels, and Bluetooth panels native.
- Support arrow navigation, Return/Space, prefix search, Escape, and dismissal by clicking outside. Skip disabled items and separators; scroll long menus to the selected item.
- Restore focus to the invoking control when a menu or overlay closes. Escape dismisses the topmost menu before its containing editor.
- If a field has no enabled alternative value, show its value without a dropdown. Check alternatives against the current value, not item count: a single enabled replacement for an unavailable current value must remain selectable.

## Keyboard and accessibility

- Make workflows usable without a mouse. Scope shortcuts to the relevant focus; list actions must not intercept text editing or controls inside an editor.
- Use semantic platform colors and support light/dark appearance, larger text, and Reduce Motion. Never communicate state through color alone. Give symbolic controls meaningful accessibility labels.
- Hidden `NSHostingView`/`NSWindow` tests can verify layout and callbacks without activating the app or sending input to the user's desktop. They do not establish real mouse/keyboard behavior or VoiceOver support; report those checks separately.
