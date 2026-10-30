# kokoko

A clean-room sample manager for the EP-133 K.O. II / EP-1320 / EP-40 family of samplers. Native SwiftUI app for iOS (iPad) and macOS, text-mode UI by design.

## Status

Protocol, transport, and audio layers are implemented and covered by runnable checks. The app shell typechecks and launches on macOS. Everything that touches real hardware still needs on-device verification — see "Open items" in [docs/protocol.md](docs/protocol.md).

## Layout

- `Sources/KokokoCore` — wire protocol: 7-bit packing, frame codec, command-5 file messages, events, filename rules, CRC-32.
- `Sources/KokokoMIDI` — CoreMIDI transport, SysEx request/response session, chunked file service.
- `Sources/KokokoAudio` — WAV parse/write, resample to the device format (46875 Hz s16) via AVFoundation.
- `Sources/KokokoCoreChecks` — self-check suite (no test framework in Command Line Tools).
- `App/Sources` — SwiftUI app shared by iOS and macOS targets.
- `docs/protocol.md` — protocol notes from static analysis of the reference tool.

## Run

```bash
swift run KokokoCoreChecks   # checks
swift run kokoko-mac         # macOS UI smoke run (no Xcode needed)
```

## App builds (requires Xcode)

```bash
brew install xcodegen
xcodegen generate
open kokoko.xcodeproj
```

One target, both platforms: pick `kokoko > My Mac` for macOS or an iPad destination for iOS. For a physical iPad set your development team under Signing & Capabilities.

## Notes

- No affiliation with teenage engineering. No assets, names, or code from the original tool; the protocol was documented from its published web bundle.
- iPadOS has no WebMIDI, which is why this is a native app: CoreMIDI over USB-C talks to the device directly.
