# Sound columns and viewport

The sound list chooses one column plan from its width and measured monospaced font. Grip, slot, waveform, size and action tracks keep the same widths across rows; only the name takes the remaining space. Placeholders and bars occupy the same waveform track. The size track also reserves the full drop feedback text. Editors and expanded details grow below the header without shifting its tracks.

The list switches all rows to compact waveform and action controls together when the expanded tracks and name allowance do not fit. If even compact tracks exceed the pane at the current text size, one shared horizontal range preserves the text and hit sizes. A fitting pane has no horizontal range. The vertical List, selection, drafts and native row containers remain in place through resizing.

## Mac viewport eligibility

Passive probes attached to the real waveform controls report public ancestor clipping and their own window/application state. Both vertical and horizontal clip ancestors are included. Eligibility means inside the app's currently active, unobstructed list viewport, not proof that a pixel is visible behind arbitrary external windows.

Automatic reads require an attached, nonhidden control in a visible, active, nonminimized window. Known app presentations and overlapping public group rows block eligibility. `NSView.visibleRect` describes ancestor clipping, not sibling or external-window occlusion. The native view is held weakly and its current clip/window facts are checked again before a read; cached callback facts alone cannot grant production eligibility.

Each receipt has a device/listing/content context and a native owner. Replacement or retirement withdraws that owner's work; an old callback cannot pin a replaced slot. Callback delivery records private facts, then one coalesced main-actor task updates the row cache outside native layout/update callbacks. Receipts arriving during a publication are reconciled again rather than dropped.

Accepted peak records in the eligible viewport are pinned in the existing row cache. Its capacity is `max(64, current viewport pin count)`; unpinned LRU entries are evicted first. Offscreen, detached, hidden or obsolete contexts lose pins. With no pins, the previous 64-entry bound remains. This bound concerns reduced peak records, not the separate PCM read budget.

## UIKit boundary

The UIKit adapter is compile-checked only. Its scroll invalidation through the hosted List has not been verified at runtime, so `tracksScroll` remains false and it grants zero automatic eligibility. Real iPad runtime evidence is required before automatic filling can be enabled there. iPhone support remains planned. This is not a permanent manual-loading fallback or a waiver of automatic loading.

## Checks and limits

```bash
swift run --scratch-path dist/checks kokoko-mac --check-native-row-drop
swift run --scratch-path dist/checks kokoko-mac --check-waveform-validity
```

The Debug entrypoints exit before normal activation, device watching or scanning. Native row checks cover column positions, full drop feedback, expansion, resizing, selection/drafts/source identity, both scroll axes, offscreen/detached probes and presentation gates. Waveform checks include a real hidden production viewport with more than 64 clipping intersections and zero GET/pins, plus separately labeled positive policy-fact tests for larger pinned sets and stable disk loads. Hidden-window intersections prove geometry only, never positive eligibility.

These checks do not prove real keyboard/focus delivery, VoiceOver, hardware, native human drag/Finder or compositor occlusion. The existing AppKit reentrant-table-delegate warning remains separately investigated; these checks do not establish its cause or impact. Read limits, foreground handoff and cache policy are described in [waveform preview policy](waveform-preview-policy.md).
