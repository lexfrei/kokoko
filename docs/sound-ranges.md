# Sound range tabs

ALL is selected by default and shows the complete grouped list. A named tab shows only its slot range, even when that range is empty. Its underline marks the chosen filter; scrolling does not change the active tab. The controls wrap at narrow widths rather than hiding choices in a menu.

| Tab | Slots |
| --- | --- |
| KICK | 001-099 |
| SNARE | 100-199 |
| CYMB | 200-299 |
| PERC | 300-399 |
| BASS | 400-499 |
| MELOD | 500-599 |
| LOOP | 600-699 |
| USER1 | 700-799 |
| USER2 | 800-899 |
| SFX | 900-999 |

These are positional labels, not audio classification or a firmware capacity limit. ALL keeps slots outside these ranges under other slots. Choosing a range does not change upload placement, renumber sounds or restrict move destinations.

## Search, selection and edits

The name/slot query is preserved when switching range and applies within that range. An empty range is distinguished from a populated range with no search matches. The total count still describes the whole listing; shown counts the current range and query results.

Selection is restricted to rows that pass both filters. Switching back to ALL or clearing a query does not restore hidden selections, so bulk actions cannot silently include them.

Unsaved or invalid inline input, a pending inline read/write, and unresolved edit readback protect range and search changes. The controls show `save or cancel the edit to change range/search` beside them. An unchanged editor closes without writing when either filter changes; equivalent padded slot input and no-write rename input count as unchanged. A failed metadata read with no draft can also close. A busy device or an expanded read-only waveform alone does not lock navigation. Main-tab and row-selection behavior is otherwise unchanged.

The controls use native Button focus and activation, with distinct focus targets and selected traits. Each named control declares its name and numeric range as its accessibility label. The selection underline is separate from keyboard focus.

## Checks and limits

```bash
swift run KokokoCoreChecks
swift run kokoko-mac --check-range-tabs
```

The second command is debug-only and exits before normal activation, device watching or scanning. It uses real AppState bindings and the same action closures as the production buttons. Geometry preferences measure the actual tab and underline views at narrow/wide widths and Dynamic Type settings; there are no copied controls, general-pasteboard operations, hardware calls or OS input injection.

Hidden NSHostingView accessibility children were empty in this setup, so geometry is not presented as an accessibility-tree test. VoiceOver exposure and spoken output, real keyboard delivery, and visible focus behavior remain manual checks.

Hidden list-mutation checks can emit AppKit's `Application performed a reentrant operation in its NSTableView delegate. This warning will become an assert in the future.` The warning also occurs without range navigation, including with row-release publication deferred. Its cause and behavior in a normal interactive session are unverified; it is not treated as a harmless message.
