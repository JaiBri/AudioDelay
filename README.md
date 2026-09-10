<div align="center">

<img src="Resources/icon.png" width="128" alt="AudioDelay icon">

# AudioDelay

**Play your Mac's audio on several speakers at once, each with its own delay and volume, from the menu bar.**

[![Download](https://img.shields.io/badge/Download-AudioDelay.dmg-2A8CF0?style=for-the-badge&logo=apple&logoColor=white)](../../releases/latest)

[![Platform](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Architecture](https://img.shields.io/badge/Universal-Apple%20Silicon%20%2B%20Intel-blue)]()
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift&logoColor=white)]()
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

[Install](#install) · [How it works](#how-it-works) · [Troubleshooting](#troubleshooting)

</div>

---

## Why

I wanted to delay my Mac's audio output. macOS can't, and the apps I found were DAWs, dead, or both. So I built this with [Claude](https://claude.ai/code).

Fixes sound arriving before picture: laggy projectors, TVs, streams, wireless headphones. And since 1.1 it plays the same audio on several outputs at once — a wired pair in one room, a Bluetooth speaker in the next — with a separate delay per speaker so you can line them up by ear.

## Install

Download the [`.dmg`](../../releases/latest) and drag AudioDelay to Applications.

**First launch:** the app isn't notarized, so macOS blocks it once.

- **macOS 15 and later:** open it, dismiss the warning, then System Settings → Privacy & Security → scroll down → **Open Anyway**.
- **macOS 13–14:** right-click AudioDelay, hit **Open**, confirm.

Then it asks for two things:

- **An audio driver.** macOS gives apps no way to capture system audio, so AudioDelay uses [BlackHole](https://github.com/ExistentialAudio/BlackHole). Click Install and it downloads and installs it for you. Needs your admin password, because drivers install system-wide.
- **Microphone permission.** Reading from BlackHole counts as audio input. It never touches your real mic.

Then tick the speakers you want, turn it on, drag the sliders. Each speaker has its own volume and delay. Settings are remembered per device, so a Bluetooth speaker that goes to sleep comes back with the same delay and volume and rejoins automatically.

## How it works

Your Mac plays into BlackHole, AudioDelay reads it back out, holds it, and sends it to every speaker you enabled. One capture feeds a shared buffer; each speaker has its own playback engine reading from that buffer at its own offset.

<div align="center">
<img src="Resources/flow.svg" width="820" alt="System audio flows into BlackHole, through AudioDelay's ring buffer, then out to your chosen device">
</div>

Off means bypassed. macOS goes straight to your speakers.

BlackHole and your speakers run on separate clocks, so the buffer between them slowly fills or drains. The app trims each speaker's read rate by a few parts per million to hold its delay steady, which is far too small to hear.

The delay slider is the *perceived* delay: the app subtracts what each device reports as its own latency (a Bluetooth speaker adds around 200 ms on its own), so two speakers set to the same value should be close to in sync. Each speaker shows its minimum; below that the slider is clamped and that speaker will lag the others.

## Details

- Any number of speakers, each 0 to 5 s in 0.01 s steps and 0 to 100 % volume, adjustable while playing
- 30 ms crossfade on delay changes and a 20 ms volume ramp, so no clicks
- Speakers that disconnect drop out on their own; the rest keep playing. When they come back they rejoin with their saved settings
- Processing rate of 44.1, 48 or 96 kHz, plus an optional bit-exact mode for wired outputs (see Limits)
- Universal binary, ~1.7 MB, no dependencies
- Adds itself to login items
- Goes online exactly once, to fetch the BlackHole installer on first launch

## Troubleshooting

**macOS still refuses to open it.** `xattr -cr /Applications/AudioDelay.app`

**No audio when on.** Check the status line. Green means audio is flowing, so check the device's volume. Orange means macOS isn't routed to BlackHole.

**Denied the microphone prompt.** System Settings → Privacy & Security → Microphone, enable AudioDelay, turn the delay on again.

**Driver install failed.** Install [BlackHole](https://github.com/ExistentialAudio/BlackHole/releases/latest) yourself and reopen AudioDelay. Sometimes needs a reboot to appear.

**Crackling or dropouts.** Raise the output device's buffer size in Audio MIDI Setup.

**Microphone prompt after every rebuild.** The signature changes each build, so macOS sees a new app.

**A speaker disappeared.** Only that speaker stops; the others keep playing. It rejoins by itself when it is back. If every enabled speaker is gone the app hands the Mac its direct route back and waits.

**I picked a speaker in System Settings and the delay came back on.** Speakers that are enabled in the app are treated as the app's own: macOS makes a Bluetooth speaker the default output every time it reconnects, and the app restores its route. To bypass, turn the delay off in the app, or pick a device that is not enabled in it.

**It crashed or was force-quit and now there's no sound.** Reopen AudioDelay — it restores the route. Or pick your speakers under System Settings → Sound.

**Surround came out in stereo.** The delay path is stereo. Turn it off for untouched multichannel.

## Building

```bash
swift build -c release
swift test
./build-app.sh              # install to ~/Applications
./build-dmg.sh              # distributable dmg into dist/
./make-icon.swift           # regenerate the icon
```

macOS 13+ and the Command Line Tools. Full Xcode isn't needed: `swift build --arch arm64 --arch x86_64` requires it, building each slice against its own triple and merging with `lipo` doesn't. `swift test` needs an Xcode 16-era toolchain (Swift Testing).

The icon is drawn by `make-icon.swift`, not checked in as an image.

## Limits

The delay path is stereo at the processing rate you pick (48 kHz by default). Direct mode is untouched. BlackHole 2ch folds surround down; use 16ch if you need the channels.

Bluetooth is always lossy: macOS sends AAC or SBC over A2DP and no app can change that. Bluetooth speakers also run at 44.1 kHz, so they are resampled from the processing rate. The wired path is different: set the processing rate to match your source (44.1 kHz for most lossless music) and no resampling happens. Even then the drift correction interpolates between samples; turn on *Bit-exact wired output* under Advanced to read whole samples instead. Drift is then corrected by a 30 ms crossfade every few minutes, and the mode applies at 100 % volume on wired speakers running at the processing rate.

Small latency floor from the audio chain itself, shown in the panel. The slider approximates perceived delay, not just the buffer.

Releases are ad-hoc signed, not notarized, so updating to a new version re-asks for the microphone permission — macOS sees each build as a new app.

If the login item doesn't take, run `./install-login-item.sh`.

## Credits

[BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio does the hard part. It isn't bundled here: the source is GPLv3 but the compiled installers are all rights reserved, so AudioDelay downloads the official signed installer instead, pinned to a version and checksum.

## License

MIT, see [LICENSE](LICENSE).
