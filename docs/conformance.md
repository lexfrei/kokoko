# Protocol conformance matrix

One row per message in [protocol.md](protocol.md). Columns:

- **kokoko**: where the client builds or parses the message, as `file` `symbol`.
- **vep**: whether `Sources/VirtualEP/VirtualEPDevice.swift` answers it, and in which function.
- **checks / e2e**: the label of a check in `swift run KokokoCoreChecks` or `swift run kokoko-e2e` that exercises it. Labels are quoted so they can be found with grep.
- **hardware**: taken only from "Verified on real hardware (EP-133, os 2.5.1)" in protocol.md, probe runs of 2026-10-30. Everything not stated there is "unverified".

Paths are relative to `Sources/`.

## Discovery and top-level commands

| Message | kokoko | vep | checks / e2e | hardware |
| --- | --- | --- | --- | --- |
| Identity request / reply | `KokokoCore/TEFrame.swift` `Identity`; `KokokoMIDI/SysExSession.swift` `identifyDevice` | yes, `handle` | checks "identity request", "identify sku"; e2e "identify sku" | verified: reply decodes to `TE032AS002`, `base_sku` `TE032AS001` |
| 1 GREET | `KokokoMIDI/SysExSession.swift` `greet`; `KokokoCore/TEFrame.swift` `GreetMetadata` | yes, `handle` | checks "greet request bytes", "session greet os"; e2e "greet os", "greet serial" | verified: `mode`, `os_version`, `serial`, `sku`, `base_sku` present |
| Debug log frame (byte 5 = `33`) | `KokokoCore/TEFrame.swift` `TEFrame.parse` (`deviceLog`); `KokokoMIDI/SysExSession.swift` `setLogHandler` | not emitted | checks "device log kind", "device log text" | unverified |
| 2 ECHO | no API; sent only through `KokokoMIDI/SysExSession.swift` `call` | yes, `handle` | checks "packed payload in frame", "session timeout" | unverified |
| 3 DFU | not implemented | no: answers status 2 (command not found) | none | unverified |
| 127 PRODUCT_SPECIFIC | no API; sent with an empty payload only by `kokoko-explore --command-scan` through `KokokoMIDI/SysExSession.swift` `call` | no: answers status 2 | none | unverified |

## Command 5: FILE

| Message | kokoko | vep | checks / e2e | hardware |
| --- | --- | --- | --- | --- |
| 1 INIT | `KokokoCore/FileMessages.swift` `FileInitRequest`, `FileInitResponse`; `KokokoMIDI/DeviceFileService.swift` `initialize` | yes, `handleFile` | checks "file init request", "file init chunk size"; e2e "file service initialized" | verified |
| 2 PUT init and data | `KokokoCore/FileMessages.swift` `PutInitRequest`, `PutInitResponse`, `PutDataRequest`; `KokokoMIDI/DeviceFileService.swift` `put` | yes, `handleFile` | checks "put init request", "put data"; e2e "put returned id", "restored original node ids" | verified: upload lands under a device-assigned `NNN.pcm` name |
| 2 PUT of a directory | `KokokoMIDI/DeviceFileService.swift` `put(isDirectory:)` | yes, accepts it | e2e "bin delete refuses a folder" | rejected under `/sounds`: `can only create files` |
| 3 GET init and data | `KokokoCore/FileMessages.swift` `GetInitRequest`, `GetInitResponse`, `GetDataRequest`, `GetDataResponse`; `KokokoMIDI/DeviceFileService.swift` `get` | yes, `handleFile`; ignores the offset | checks "get init request", "get data payload"; e2e "round trip bytes" | verified: readback byte-identical |
| 3 GET init extra args | `KokokoCore/FileMessages.swift` `GetInitRequest.extraArgs`, no caller | ignored | none | unverified; protocol.md records a firmware crash after a guessed layout |
| 4 LIST | `KokokoCore/FileMessages.swift` `ListRequest`, `ListResponse`; `KokokoMIDI/DeviceFileService.swift` `list` | yes, `handleFile` | checks "list request", "list entries count"; e2e "seeded sounds" | verified |
| 5 PLAYBACK start / stop | `KokokoCore/FileMessages.swift` `PlaybackRequest`; `KokokoMIDI/DeviceFileService.swift` `startPlayback`, `stopPlayback` | acknowledges, plays nothing | checks "playback start", "playback stop" | unverified |
| 6 DELETE | `KokokoCore/FileMessages.swift` `DeleteRequest`; `KokokoMIDI/DeviceFileService.swift` `delete` | yes, `handleFile` | checks "delete request"; e2e "deleted node gone" | verified |
| 7 METADATA set, short form | `KokokoCore/FileMessages.swift` `SetMetadataRequest`; `KokokoMIDI/DeviceFileService.swift` `setMetadata` | yes, `handleMetadata` | checks "set metadata"; e2e "metadata name" | unverified |
| 7 METADATA get, paged | `KokokoCore/FileMessages.swift` `GetMetadataRequest`, `GetMetadataResponse`; `KokokoMIDI/DeviceFileService.swift` `getMetadata` | yes, `handleMetadata` | checks "get metadata request", "get metadata fragment"; e2e "metadata samplerate" | verified |
| 7 METADATA set, paged | `KokokoCore/FileMessages.swift` `SetMetadataPagedInitRequest`, `SetMetadataPagedDataRequest`; `KokokoMIDI/DeviceFileService.swift` `setMetadata` | yes, `handleMetadata` | checks "paged metadata init", "paged metadata data" | unverified |
| 11 INFO | `KokokoCore/FileMessages.swift` `FileInfoRequest`, `FileInfoResponse`; `KokokoMIDI/DeviceFileService.swift` `info` | yes, `handleFile` | checks "info request", "info name" | unverified |
| 12 MOVE | `KokokoCore/FileMessages.swift` `MoveRequest`, `MoveResponse`; `KokokoMIDI/DeviceFileService.swift` `move` | yes, `handleFile`; keeps the node id, emits no event | checks "move request", "move new" | unverified |

## File events

| Event | kokoko | vep | checks / e2e | hardware |
| --- | --- | --- | --- | --- |
| 3 METADATA_UPDATED | `KokokoCore/FileMessages.swift` `FileEvent.parse` | not emitted | checks "event metadata" | unverified |
| 8 FILE_ADDED | `KokokoCore/FileMessages.swift` `FileEvent.parse` | emitted after a PUT completes, `emitEvent` | checks "event added"; e2e "added event seen" | unverified |
| 9 FILE_UPDATED | `KokokoCore/FileMessages.swift` `FileEvent.parse`, same branch as 8 | not emitted | none | unverified |
| 10 FILE_DELETED | `KokokoCore/FileMessages.swift` `FileEvent.parse` | emitted after DELETE, `emitEvent` | checks "event deleted", "session event deleted node"; e2e "deleted event seen" | unverified |
| 13 FILE_MOVED | `KokokoCore/FileMessages.swift` `FileEvent.parse` | not emitted | checks "event moved" | unverified |

## Command 6: SETTINGS

| Message | kokoko | vep | checks / e2e | hardware |
| --- | --- | --- | --- | --- |
| 1 init | `KokokoMIDI/SettingsService.swift` `initialize` | yes, `handleSettings` | e2e "settings groups" | unverified |
| 2 get all, paged | `KokokoMIDI/SettingsService.swift` `getAll` | yes, `handleSettings` | checks "settings big response"; e2e "settings groups" | unverified |
| 3 set | `KokokoMIDI/SettingsService.swift` `set` | acknowledges, stores nothing | none | unverified |
