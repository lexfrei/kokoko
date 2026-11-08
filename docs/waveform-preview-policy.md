# Waveform preview policy

A stored peak record is a candidate, not evidence that the sampler still holds the same bytes. The app shows it only when the current sound node, byte size, channel count and sample rate match confirmed device metadata. Channel/rate metadata must be present, integral and supported; missing or invalid values are not guessed from a cache record or a default.

The existing listing already requests metadata for sound names. Its confirmed format is retained for previews without adding an offscreen metadata scan. Missing, failed or mismatched validation hides both miniature and expanded peaks; real operation errors remain available. Placeholders, loading text and unavailable states do not expose cache origin or invalidation status.

## Automatic filling on Mac

The active Mac list viewport fills missing waveforms automatically. [Viewport receipts](sound-columns.md) come from the real controls and public native clipping/window facts, not row appearance or the filtered library. Matching memory/disk peaks are reused before any PCM request. Offscreen, hidden, inactive, detached and known obstructed views cannot start new reads. UIKit automatic filling remains blocked pending runtime scroll validation; the cross-platform automatic feature is not complete.

One drain owns at most 32 pending candidates, one active GET and one background PCM buffer through off-main peak reduction. Each waveform read has a 16 MiB remaining-byte limit, checked before buffer allocation and before page data is copied/appended. This is an application preview budget, not a sampler firmware limit. Oversized miniatures stay neutrally unavailable; explicit opening or refresh reports the preview restriction. Ordinary file export and backup reads retain their previous unrestricted API default.

A whole GET is nonpreemptible once admitted. Losing visibility or context cancels pending work and acceptance of a late result; an already admitted transfer drains before another operation starts. The existing 20-second timeout applies to each init/page call, not the whole download. There is no promise of an overall 20-second wait or immediate cancellation.

A failed request is remembered for its current device/content/format context, with one receipt per slot, so scrolling alone does not retry it. Explicit retry, a new confirmed context or a device/content reset permits another attempt. The memo is cleared on reset and is bounded by the protocol's slot IDs. No timer, eager library scan, streaming loop or manual visible-fill control is used.

## Foreground work and file ownership

One explicit file action can wait behind the current background read. Its ownership is promoted before a subsequent background read; later conflicting actions receive a truthful not-queued refusal. Short preview, rename and slot intents remain immediate and are never replayed later. Inline drafts survive refusal, and an open inline editor pauses subsequent background reads. A waiting file action retains its payload or scoped URLs, then revalidates the captured device and relevant node/root before acting.

Drop handlers distinguish `processed` from `notStarted`; processing can include reported per-file failures and does not mean success. Staged copies are discarded only after processing. Refusal, cancellation or loss of the device before admission leaves the copies intact and reports their existing recovery directory in the private error text. Picker originals are not consumed. No automatic retry, popup or opaque operation queue is added.

## Session and persistence

Closing details, reusing a matching record or evicting an unpinned row snapshot does not invalidate confirmed metadata. Same-session reopening can show an accepted record while current metadata validation is pending, without another PCM transfer. A subsequent validation failure removes that acceptance. Closing details or cancelling a metadata editor stops that presentation, not a still-current device/content observation. Metadata obtained by details, editors and exports still removes acceptance on invalid responses or errors after UI closes.

A separate content epoch prevents observations and listing/readback snapshots from before a mutation or device reset from restoring confirmation; it is not a row-presence or presentation lease. Known sound writes, moves, deletes and restores invalidate affected preview context. Old viewport owners, lookup requests, reduction leases and cache-store tokens cannot publish a late result. Metadata edits use actual device responses and readback baselines for loop overlays, never the raw draft. An unresolved readback leaves confirmation absent.

The persistent cache is namespaced by model and serial, and validates its schema, algorithm, integrity envelope, slot, size and format. A new device session validates current listing/format before displaying a persistent candidate. This policy cannot detect an external replacement with the same size and format when the device provides no content version used by the app. Matching descriptors are an operational cache policy, not a remote-content checksum or freshness guarantee. Refreshing a waveform forces a new bounded audio read. This limit belongs here, not in a permanent warning beside every waveform.

## Other invalidated summaries

Invalidated sound counts and used/free/total storage show `?` rather than old numbers labeled as current. Confirmed zero remains zero, and fresh authoritative partial storage fields are preserved. Internal invalidation flags remain; invalidation by itself does not create an error banner or replace a real earlier error. No additional storage query is scheduled by this presentation policy.

## Checks

```bash
swift run --scratch-path dist/checks KokokoCoreChecks
swift run --scratch-path dist/checks kokoko-mac --check-waveform-validity
swift run --scratch-path dist/checks kokoko-e2e
```

The Debug app check exits before normal activation, device watching or scanning. Actual AppState, file service and session use a deterministic in-memory wire for queue, cache, cancellation, context/owner, coalescing, budget and off-main reduction-barrier tests. Native hidden-window checks separately prove clipping and zero eligibility/GET; positive policy-fact tests are explicitly labeled, not real-screen evidence. The existing e2e target uses its own VirtualEP over CoreMIDI for lower-layer bounded-reader/service/admission ordering; it does not drive AppState or justify adding simulator code to the shipped app.

These checks do not prove hardware behavior, VoiceOver, real keyboard/focus delivery, native human drag/Finder or positive active-window runtime behavior. UIKit runtime remains a prerequisite for enabling its automatic filling. The existing AppKit reentrant-table-delegate warning is not declared fixed or cosmetic.
