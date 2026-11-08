# kokoko

kokoko is a sample manager for the teenage engineering EP-133 K.O. II, EP-1320 and EP-40 samplers. It runs on iPad and Mac, talks to the device over USB-C, and has a text-mode UI by design.

## What it does

- Finds a connected device on its own and shows its name, serial and OS version. If teenage engineering's release list is reachable, it also shows whether a newer firmware exists.
- Lists sounds with slot number, name and size. Named range tabs and name/slot search share one filter; ALL includes slots outside the named ranges. Hidden rows leave the selection. [Range and search rules](docs/sound-ranges.md) describe the labels and draft protection.
- Shows total and filtered sound counts, plus the device's reported used/free/total storage in B, KiB or MiB. Missing or invalidated values show `?`, not old figures, guessed capacity or false zero. Confirmed zero and authoritative partial storage fields remain visible. List refreshes update the summaries; metadata saves, failed renames and project imports can leave them unknown until Refresh.
- Adds sounds from audio files, picked or dropped onto the list. WAV files already in the device format (16-bit, 46875 Hz, mono or stereo) are sent as they are. Other audio is converted to 16-bit at 46875 Hz first, and audio that needs converting is refused if it is longer than 40 seconds. Audio with more than two channels is refused rather than mixed down.
- Plays a one-second preview of a sound on the device.
- Shows waveform miniatures when stored peaks match the current sound size and confirmed format; narrow rows keep a neutral `[~]` control. Opening one enlarges it below the row and loads missing audio on request. Same-session reuse keeps its confirmation; missing or mismatched validation hides the preview instead of adding cache-status labels. [Waveform preview policy](docs/waveform-preview-policy.md) documents the persistent cache and same-size external-change limit. Automatic visible-row filling and shared aligned columns remain required follow-ups, not features completed by this policy change.
- Downloads a sound as a WAV file, by button or by dragging its row out of the app, and downloads a selection of sounds into a folder.
- Renames a sound and moves it to a free slot by editing its slot number in the row: click the number, press Return to move or Escape to cancel. A failed move keeps the draft and error; if the reply is lost, the app checks where the sound landed before allowing a retry. Dragging one row onto another asks before swapping their sounds. A selection of sounds can be moved, in slot order, onto the free slots counting up from a chosen number, skipping slots held by other sounds.
- Opens metadata below a sound's row from `[m]`: root note, bpm, pitch, pan, amplitude, envelope attack and release, loop points and play and time modes. `[ save ]` checks the numeric ranges in [docs/protocol.md](docs/protocol.md), sends only edited fields, and verifies the values read back. A failed save keeps the draft and error; if readback failed, retry reads the device before another write. `[ cancel ]` closes the draft without undoing writes already sent.
- Deletes one sound or a selection and keeps a copy of each in a recycle bin on the Mac or iPad. If deleting into the bin fails, it offers to delete that sound without keeping a copy.
- Lists the deleted sounds in a bin tab with their original slot, name and time of deletion. A sound can be put back, into its original slot if that slot is free and into another one otherwise, or removed from the bin for good. The bin tab works without a device; putting a sound back needs one connected.
- Backs up the sounds, the projects, or both into a folder, from the buttons on the sounds, projects and settings tabs or from the File menu. A restore, started from those tabs or the menu, first says what it will write and asks, then puts back the sounds from the chosen backup folder and its projects into the project slots that already exist on the device. A backup names and leaves out a project archive that reads short or is not a valid archive, and a restore does the same for one that is missing, unreadable or damaged.
- Lists the projects, downloads one as a `.tar` archive, and uploads archives named like `P01.tar` by dropping them onto the project list, into a slot that already exists on the device.
- Shows the device settings where the firmware exposes them.
- Keeps every tab visible, with or without a device, and says on each device tab whether it is scanning, connecting or not connected. The projects and settings tabs, opened while the device is busy, say they will load once it is free. The full text of an error opens from the footer, or from the header for a failed connection.
- Gives bracketed buttons spoken labels, such as "Delete selected" for `[ x ]`. Main tabs mark selection with `*`; sound range tabs use an underline and a selected accessibility trait.
- Puts these actions in the menu bar as well: File has Add Sounds (⌘O), downloading the selected sounds, and the three backups and the restore, which work from any tab; View switches tabs (⌘1 to ⌘4), refreshes the open tab (⌘R) and scans for devices again.
- Runs in a single window on a Mac; closing it quits the app.

## Status and limits

Checked on an EP-133 with OS 2.5.1: finding the device and reading its info, listing files, reading metadata, and sending, reading back and deleting a sound file. Everything else has not been checked on hardware yet. That includes writing a sound's name and metadata, which adding and renaming rely on, as well as slot moves, previews, the recycle bin, projects, backup and restore, and the EP-1320 and EP-40. [docs/conformance.md](docs/conformance.md) lists the status per protocol message.

The factory sounds on that device report no move and no playback permission ([docs/protocol.md](docs/protocol.md)). On that device the settings command answers command not found, and the settings tab says device settings are not exposed over MIDI on this firmware.

## Install and run

The app is built with Xcode and XcodeGen:

```bash
brew install xcodegen
xcodegen generate
open kokoko.xcodeproj
```

The `kokoko` target covers both platforms. Pick `My Mac` to run it on macOS, or an iPad as the destination. On a physical iPad, set your own development team under Signing & Capabilities.

## Development

```bash
swift run KokokoCoreChecks   # self-checks
swift run kokoko-e2e         # full protocol loop against a virtual device
swift run vep                # standalone virtual device to connect the app to
swift run kokoko-mac         # macOS UI without Xcode
swift run kokoko-probe       # read-only probe of a connected device
```

The code is a Swift package: protocol, transport, audio and library modules under `Sources/`, a device simulator, check suites, and the SwiftUI app in `App/Sources`. [docs/protocol.md](docs/protocol.md) describes the wire protocol, and [docs/conformance.md](docs/conformance.md) maps it to the code.

## License

BSD 3-Clause. The wire protocol was documented from the published ep-sample-tool and apps/update web bundles and from probe runs on an EP-133; no third-party code or assets are included.

## Notes

- No affiliation with teenage engineering. No assets, names, or code from the original tool.
- iPadOS has no WebMIDI, which is why this is a native app: CoreMIDI over USB-C talks to the device directly.
