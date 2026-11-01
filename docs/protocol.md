# EP-133/EP-1320/EP-40 SysEx file protocol

Reverse-engineered from the teenage.engineering ep-sample-tool web bundle (`index-C1wBjhTa.js`, sha256 `d032b3a1d9398663f313c54b671e366c5625f3612a2285ceaacad636cb5d7a98`). This document is our own specification of the observed wire behavior.

## Transport and discovery

MIDI SysEx over USB. TE manufacturer ID: `00 20 76`.

Discovery uses the universal identity request:

```text
F0 7E 7F 06 01 F7
```

The reply is exactly 17 bytes. Byte 2 is the device ID used later as `identity_code`. Bytes 5..7 must be `00 20 76`. The SKU is decoded from the family/model fields:

```text
sku = "TE" + (s[8] | s[9]<<7) padded to 3 + "AS" + (s[10] | s[11]<<7) padded to 3
```

Known SKUs and minimum OS versions enforced by the tool (os_version "0.1.0" is always accepted; other "0.x" counts as the beta channel):

| SKU | Device | beta min | production min |
| --- | --- | --- | --- |
| TE032AS001 | EP-133 K.O. II | 0.100.38 | 2.0.5 |
| TE032AS005 | EP-1320 medieval | 0.2.13 | 1.0.2 |
| TE032AS006 | EP-40 Riddim | 0.4.7 | 1.0.5 |

## Frame format

Request (host → device):

```text
[0]    F0
[1..3] 00 20 76
[4]    identity_code (device id from the identity reply)
[5]    40           (TE protocol marker)
[6]    40 | 20 | ((request_id >> 7) & 31)   (IS_REQUEST | REQUEST_ID_AVAILABLE | id high bits)
[7]    request_id & 127
[8]    command
[9..]  payload, 7-bit packed (see below)
[N-1]  F7
```

Response (device → host): same header with the IS_REQUEST bit (40) cleared in byte 6. Byte 9 is then the status byte; payload starts at byte 10, 7-bit packed.

Request id: 12-bit, per-output counter seeded at random, incremented mod 4096.

Status byte:

| value | meaning |
| --- | --- |
| 0 | ok |
| 1 | error |
| 2 | command not found |
| 3 | bad request |
| 16..63 | command-specific error |
| >= 64 | command-specific success; the request stays open for follow-up messages until a terminal status arrives |

A frame with byte 5 = `33` (instead of `40`) carries a UTF-8 debug log string from the device in the unpacked payload.

## 7-bit packing

MIDI data bytes must be < 128. Payload bytes are packed in groups of 7: each group is preceded by one byte whose bit `i` holds the high bit of group byte `i`. An empty payload has no packing bytes at all. Packed size for `n` payload bytes is `n + ceil(n/7)`.

## Top-level commands

| cmd | name | notes |
| --- | --- | --- |
| 1 | GREET | empty payload; reply payload is a `key:value;` metadata string |
| 2 | ECHO | payload echoed |
| 3 | DFU | firmware update, see below |
| 6 | SETTINGS | device settings JSON: sub 1=init, 2=get-all (paged), 3=set |
| 127 | PRODUCT_SPECIFIC | not used by the sample tool |

GREET metadata string keys: `chip_id`, `mode` (`normal`/`bootloader`), `os_version`, `product`, `serial`, `sku`, `sw_version`, `base_sku`. Example shape: `chip_id:...;mode:normal;os_version:2.1.0;...`.

## Command 5: FILE

All file operations use command 5; the first payload byte is the subcommand. Multi-byte integers are big-endian. Filenames on the wire are null-terminated UTF-8.

| sub | name |
| --- | --- |
| 1 | INIT |
| 2 | PUT |
| 3 | GET |
| 4 | LIST |
| 5 | PLAYBACK |
| 6 | DELETE |
| 7 | METADATA |
| 11 | INFO |
| 12 | MOVE |

### INIT

Request: `[01 flags max_response_len:u32]`. `flags & 1` subscribes to file events. The tool sends max_response_len = 4 MiB.

Reply payload: `[xx chunk_size:u32]` (first byte ignored). `chunk_size` is the device's max SysEx payload per message and drives all chunking below.

Max raw payload per chunk message:

```text
overhead = 8 (header) + 2 + 1 (footer) = 11
m = chunk_size - 6
if m <= 11: 0
else: p = m - 1 - 11; p - floor(p/8)
```

### PUT (upload)

Init request: `[02 00 flags file_id:u16 parent_id:u16 file_size:u32 filename:z metadata_json:z]`

- `flags`: capability bits OR'd with file type. Capabilities: READ=4, WRITE=8, DELETE=16, MOVE=32, PLAYBACK=64. Type: FILE=1, DIR=2.
- `file_id` 0 = auto-assign.
- filename truncated to 54 bytes.
- metadata JSON may be empty.

Init reply: `[file_id:u16]`.

Data messages: `[02 01 page:u16 chunk...]`, page counter starting at 0, chunk size from the formula above. Terminated by a data message with an empty chunk.

### GET (download)

Init request: `[03 00 file_id:u16 offset:u32]` plus optional 8 zero bytes and extra args (used for partial/preview reads; semantics not fully verified).

Init reply: `[file_id:u16 flags file_size:u32 name:z]`.

Data request: `[03 01 page:u16]`.

Data reply: `[page:u16 data...]`; next page = page + 1 (mod 65536). Empty data ends the transfer. Download integrity is checked client-side with CRC-32 (ISO-HDLC, reflected, poly `EDB88320`).

### LIST

Request: `[04 page:u16 node_id:u16]`.

Reply: `[page:u16 entries...]`; each entry is `[node_id:u16 flags file_size:u32 name:z]`. The page counter must match the request; a reply of ≤ 2 bytes ends the listing.

### INFO

Request: `[0B file_id:u16]`.

Reply: `[node_id:u16 parent_id:u16 flags file_size:u32 name:z]`.

### DELETE

Request: `[06 file_id:u16]`.

### PLAYBACK

Request: `[05 action file_id:u16 offset:u32 length:u32]`, action 1 = start, 2 = stop. The tool uses offset 0, length 0 or 1000 ms for previews.

### METADATA

Set (short form): `[07 01 file_id:u16 json:z]`.

Get: `[07 02 file_id:u16 page:u16 key:z?]` — key optional.

Get reply: `[page:u16 json_fragment:z]`; keep paging until a fragment ends in a 0 byte.

Set (paged, when the JSON exceeds `chunk_size - 8`): init `[07 04 00 file_id:u16 total_size:u32]`, then data `[07 04 01 page:u16 chunk...]`, terminated by an empty data message.

### MOVE

Request: `[0C file_id:u16 parent_id:u16 new_file_id:u16]`.

Reply: `[old_file_id:u16 parent_id:u16 new_file_id:u16]`. The tool tolerates a timeout here and re-reads state afterwards.

### Events (device-initiated, require INIT subscribe flag)

Arrive as frames without a request id; payload byte 0 is the event kind:

| kind | event | payload after kind |
| --- | --- | --- |
| 3 | METADATA_UPDATED | `[node_id:u16 json:z]` |
| 8 | FILE_ADDED / 9 = FILE_UPDATED | `[node_id:u16 xx xx:2 file_size:u32 name:z]` (size at bytes 5..8, name at 9) |
| 10 | FILE_DELETED | `[node_id:u16]` |
| 13 | FILE_MOVED | `[old_node:u16 parent:u16 new_node:u16]` |

## Filesystem semantics

The device exposes a virtual tree addressed by numeric node ids:

```text
/sounds
/projects/P01..P09
/projects/Pxx/groups/A..D
/projects/Pxx/groups/Y/pads/01..12
```

Pad assignment is metadata: `{"sym": <sound_node_id>}` on the pad node. Active project/group/pad selection: `{"active": <node_id>}` on the corresponding parent node.

Supported audio formats are device-advertised: read metadata key `formats` of the `/sounds` node. The tool picks the PCM format containing `s16`, clamps to its `samplerate.range` upper bound or `samplerate.native`, defaulting to **46875 Hz**.

## Sound upload rules (observed in the tool)

- Source must decode as audio; input sample rate 3000..768000 Hz; max length 40 s.
- Target format: 46875 Hz s16 PCM, mono or stereo per device-advertised formats.
- Fast path: a WAV that is already s16 at the target rate with 1-2 channels is sent as-is (raw `data` chunk slice, no re-encode).
- Otherwise: decode, resample (libsamplerate in the original), encode s16 PCM.
- After PUT completes, sound metadata is set on the new node.

Filename normalization (upload + rename): optionally strip a leading `NNN` followed by a space, drop the extension, remove `/`, trim, NFD-normalize and strip diacritics, replace non-ASCII with `?`, remove `\` and `"`, if longer than 16 chars keep first 7 + `.` + last 8, lowercase.

## Sound metadata JSON keys and validators

| key | constraint |
| --- | --- |
| channels, samplerate, name | set by the tool on upload |
| sound.loopstart, sound.loopend | >= 0, rescaled by the target/source rate ratio |
| sound.rootnote | 1..127 |
| sound.bpm | 60..180 |
| sound.pitch | -12..12 |
| sound.pan | -16..16 |
| sound.amplitude | 0..200 |
| envelope.attack, envelope.release | 0..255 |
| sound.playmode, time.mode | non-empty string |
| regions | passed through from the source JSON chunk |

Download-as-WAV embeds the metadata back into the WAV (loop points, root note, bpm, and a JSON chunk with the keys above).

## Project archives and factory restore

Project backups are TAR files named `*P01.tar`-style; upload goes to `/projects` with capability READ. The reference tool waits 15 s for this upload; kokoko waits 60 s. "Restore factory sounds" downloads a hosted `.pak` (e.g. `/apps/ep-sample-tool/assets/ep-133-factory-content-*.pak`) and uploads it like a project archive — not a protocol feature.

## Firmware update (DFU, command 3)

Documented from the teenage.engineering/apps/update bundle (index-DjKrxGFA.js).

Firmware file (.tfw): magic `BA BE CA FE`, byte 4 = firmware_type (0 = regular), bytes 5-6 = checksum, bytes 7-14 = version as four u16 (`major.minor.patch` + optional `+build`), bytes 15-18 = packed sku u32, payload from offset 64. A regular firmware carries a device id at offset 68; device id 6 marks a content pack (factory sounds also ship as .tfw).

Flow:

1. Send `[02 <version:8> B0 <sku:4> <size:4 BE> <type>]` (DFU_BEGIN). Reply bytes 0-1 = chunk size. If the reply starts with 64 (`DFU_ENTER_RESPONSE_READY`) the update runs in-app; a bad-request status means reboot to bootloader first (`01 01 00 C8`) and resend begin.
2. Chunks: `[03 <n % 256> <data...>]`; chunk payload = `ceil(chunkSize * 7/8) - 12` bytes.
3. `[04]` (DFU_PERFORM) — progress replies: byte 0 = percent, optional `[label]` text.
4. `[05]` (DFU_EXIT) — reply byte 0 × 3 = expected reboot seconds (default 60). Wait for the device to reappear, greet, compare `os_version`.

Latest firmware per SKU: `https://teenage.engineering/_software/releases.json` (version, `fw_url`, release notes). Match devices by `base_sku` — a device reporting `TE032AS002` maps to the `TE032AS001` entry. Devices also accept a dropped `.tfw` file directly.

## Settings (command 6)

- init: `[01 <page_size:u16>]`
- get all: `[02 <page:u16>]` → text fragment from byte 2 until a 0 byte; page until empty
- set: `[03 <id:u16> <json...> 00]`

Documented from the teenage.engineering/apps/update bundle. On EP-133 os 2.5.1 init answers command not found; see "Verified on real hardware".

## Open items to verify on the wire

- GET init extra args: `[01 start:u16 length:u16]` used for preview reads; exact semantics unverified. HAZARD: an attempt with this guessed layout preceded a firmware crash (siren screen, code 69) on EP-133 os 2.5.1. Do not send extra args until the layout is verified against captured traffic.
- Whether PUT init metadata is honored (the current bundle sends an empty object there and sets metadata afterwards).
- EP-1320/EP-40 deviations (the tool has per-SKU UI but a shared protocol).

## Verified on real hardware (EP-133, os 2.5.1)

Probe runs over USB-C, 2026-10-30: a read-only pass, a write test, then a settings dump.

- Identity reply decodes to `TE032AS002` (not AS001) with `base_sku: TE032AS001` — match devices by base_sku.
- GREET metadata contains `mode`, `os_version`, `serial`, `sku`, `base_sku` as documented.
- Real node ids are sparse: `/sounds` = 1000, `/projects` = 2000, sounds numbered from 1. Resolve by walking names, never assume ids.
- Factory sounds live in `/sounds` as `NNN.pcm`; observed flags `0x1D` (file | read | write | delete — no move, no playback).
- `/sounds` metadata answers the open free-space question: `{"max_capacity": 127801344, "free_space_in_bytes": ..., "formats": [...]}`.
- Advertised format: pcm `s16`, channels 1-2, `samplerate.native` 46875, `samplerate.range` 1..65535 — the documented defaults hold.
- File init, list and paged metadata get work over UMP event lists at the negotiated chunk size.
- Full write path verified: PUT upload lands with a device-assigned slot name (`032.pcm` for a file sent as `kokoko-test`), GET readback is byte-identical, DELETE removes it. Display names live in metadata `name`; the wire filename is rewritten to `NNN.pcm`.
- Directories under `/sounds` are rejected by firmware: `can only create files`. Sample organization is a flat pool plus pad assignment via `{"sym": node_id}` metadata.
- Settings (command 6): the settings dump sent init `[01 <page_size>]`, and the device answered command not found, so get-all and set were not sent.
