# Waveform preview policy

A stored peak record is a candidate, not evidence that the sampler still holds the same bytes. The app shows it only when the current sound node, byte size, channel count and sample rate match confirmed device metadata. Channel/rate metadata must be present, integral and supported; missing or invalid values are not guessed from a cache record or a default.

The existing listing already requests metadata for sound names. Its confirmed format is retained for previews without adding PCM reads for offscreen rows. Explicit waveform opening also obtains current metadata. Missing, failed or mismatched validation hides both miniature and expanded peaks immediately; real operation errors remain available. Placeholders, loading text and unavailable states do not expose cache origin or invalidation status.

## Session and persistence

Closing details, reusing a matching record or evicting a row snapshot does not invalidate confirmed metadata. Same-session reopening can show the accepted record while current metadata validation is pending, without another PCM transfer. A subsequent validation failure removes that acceptance. Closing details or cancelling a metadata editor stops updates to that presentation, not the validity of a still-current device/content observation. Metadata obtained by details, editors and exports still removes acceptance on invalid responses or errors after UI closes. A separate content epoch prevents observations and listing/readback snapshots from before a mutation or device reset from restoring confirmation; it is not a row-presence or presentation lease.

Device reset clears confirmation. A new session must validate the listing/format before displaying a persistent candidate. Known sound writes, moves, deletes and restores invalidate affected preview context; old leases, lookup epochs and cache-store tokens cannot publish or store a late result. Metadata edits use only actual device responses and readback baselines for loop overlays, never the user's raw draft text. An unresolved readback leaves confirmation absent until a successful validation.

The persistent cache is namespaced by model and serial, and validates its schema, algorithm, integrity envelope, slot, size and format. This policy cannot detect an external replacement with the same size and format when the device provides no content version used by the app. Matching descriptors are an operational cache policy, not a remote-content checksum or a freshness guarantee. Refreshing the waveform forces a new audio read. This limit belongs in documentation, not a permanent warning beside every waveform.

## Other invalidated summaries

Invalidated sound counts and used/free/total storage show `?` rather than old numbers labeled as current. Confirmed zero remains zero, and fresh authoritative partial storage fields are preserved. Internal invalidation flags remain; invalidation by itself does not create an error banner or replace a real earlier error. No additional storage query is scheduled by this presentation policy.

## Scope of this change

This policy covers validity and neutral presentation. [Shared row columns and bounded viewport checks](sound-columns.md) are documented separately. Automatic bounded fills with foreground-operation priority remain required work; no timer, automatic audio filling, GET size limit, admission waiter or streaming change is implemented here. UIKit scroll eligibility needs runtime validation before automatic filling can be enabled there. A manual visible-fill control is not a substitute.

## Checks

```bash
swift run KokokoCoreChecks
swift run kokoko-mac --check-waveform-validity
```

The second command is debug-only and exits before normal activation, device watching or scanning. It runs the real AppState, file service and session against a deterministic in-memory wire, not a connected MIDI endpoint. Tests cover close/reopen and row eviction, descriptor validation and hiding, device reset, late metadata/PCM responses, own invalidation, metadata SET/readback versus raw draft, and preserved real errors. Cache fixtures use session-owned temporary directories below the home directory so the cache's symlink restrictions remain in effect.

These checks do not prove hardware behavior, VoiceOver exposure, real keyboard delivery or visible native focus. The existing AppKit reentrant-table-delegate warning from hidden list mutation remains separately investigated; this change does not claim to fix it.
