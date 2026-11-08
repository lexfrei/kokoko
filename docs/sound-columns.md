# Sound columns and viewport checks

The sound list chooses one column plan from its width and measured monospaced font. Grip, slot, waveform, size and action tracks keep the same widths across rows; only the name takes the remaining space. Placeholders and bars occupy the same waveform track. Editors and expanded details grow below the header without shifting its tracks.

The list switches all rows to compact waveform and action controls together when the expanded tracks and name allowance do not fit. If even compact tracks exceed the pane at the current text size, one shared horizontal range preserves the text and hit sizes. A fitting pane has no horizontal range. The vertical List, selection, drafts and native row containers remain in place through resizing.

## Bounded viewport feasibility

The Debug checks attach passive probes to actual waveform controls. They do not read audio or schedule work. Eligibility means inside the app's currently active, unobstructed list viewport, not proof that a pixel is visible behind arbitrary external windows.

On macOS, probes use public view conversion, ancestor clipping, clip bounds/frame notifications and their own window/application state. Both vertical and horizontal clip ancestors are included. Detached, hidden, minimized or inactive windows and known app presentations refuse eligibility. `NSView.visibleRect` describes ancestor clipping, not sibling or external-window occlusion; known app obstructions must be gated separately. A positive rectangle in a hidden window is geometry evidence only, never positive eligibility.

The existing native row checks cover cross-row column coordinates, bars/placeholders, inline expansion, resizing, selection/draft/source identity, real vertical and horizontal scroll notifications, partial clipping, offscreen and detached probes, hidden-window refusal and known presentation gates. They assert zero protocol commands. Positive eligibility tests use explicit policy facts and are labeled separately from actual hidden-window geometry checks.

The UIKit adapter is compile-checked only. Its scroll invalidation through the hosted List has not been verified at runtime, so `tracksScroll` remains false and it grants zero eligibility. This blocks enabling automatic waveform loading on UIKit until real iPad runtime evidence exists. iPhone support remains planned. It is not a permanent manual-loading fallback or a waiver of automatic loading.

## Remaining work

Automatic visible-row filling still requires bounded audio reads and foreground-operation admission. No automatic metadata or PCM GET, timer, scheduler, admission or transfer-loop change is included here. UIKit runtime validation is a prerequisite for enabling that work there.

```bash
swift run kokoko-mac --check-native-row-drop
```

This Debug entrypoint exits before normal activation, device watching or scanning. It does not prove real keyboard/focus delivery, VoiceOver, hardware, native human drag/Finder or compositor occlusion. The existing AppKit reentrant-table-delegate warning remains separately investigated; these checks do not establish its cause or impact.
