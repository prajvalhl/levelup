# LevelUp for macOS

LevelUp is a native macOS menu-bar app that routes system audio through a real-time compressor and peak limiter before sending it to the Mac's current physical output. It is designed to make quiet content easier to hear while reducing the level difference between quieter and louder passages.

The latest published release is **0.2.1**. Version **0.2.2** has been prepared and verified locally but is not yet published; v0.2.1 remains the latest public download. LevelUp runs on **Apple Silicon (ARM64)** Macs with **macOS 14.4 or later**. It uses Apple's built-in Core Audio APIs and does not install a virtual audio driver.

## What LevelUp does

- Captures system audio locally with a Core Audio process tap.
- Passes audio through unchanged in Bypass, or processes it with the Gentle, Balanced, Strong, or Custom compressor/limiter settings.
- Follows the current macOS default output. When that output changes or disconnects, LevelUp safely cleans up the old route and attempts to build a fresh route for the new default.
- Responds to macOS sleep and wake notifications: it requests ordered route cleanup before sleep and resolves the current default output before bounded recovery after wake.
- Uses the custom LevelUp logo in both the menu bar and popover header. The menu-bar image uses macOS template rendering to adapt to light and dark appearances; the popover renders the logo in white over its blue gradient tile. If the popover image is missing or cannot be decoded, LevelUp logs the issue and displays the waveform SF Symbol. The popover also provides controls for starting, stopping, selecting a mode, and editing supported Custom parameters.
- Restores normal playback by stopping the route and releasing its Core Audio resources.

LevelUp does not record or save audio, send audio over a network, install drivers or background services, or change the system's default output device. The system-audio capture permission is required because the process tap reads system audio; permission does not mean audio is stored or transmitted.

## Install and use

### Install from the DMG

1. Download the latest published versioned DMG from a GitHub Release (`LevelUp-v0.2.1.dmg` until v0.2.2 is published) and open it.
2. Drag `LevelUp.app` to the `Applications` shortcut in the mounted image, then eject the image.
3. Open LevelUp from Applications. Because this free build is ad-hoc signed and not notarized, macOS may show an unidentified-developer or “Apple cannot check” warning. After the first blocked launch, open **System Settings → Privacy & Security**, find the LevelUp notice, choose **Open Anyway**, and confirm the next prompt. Only do this if you trust the source you downloaded. Do not disable Gatekeeper globally. See Apple's [per-app approval instructions](https://support.apple.com/guide/mac-help/mh40617/27/mac/27).
4. Start playing audio in another app before starting LevelUp. When macOS asks, grant system-audio capture permission. It appears in **System Settings → Privacy & Security → Screen & System Audio Recording** on recent macOS versions; wording can vary on older supported releases. If LevelUp is not listed, use the add control to select it. See Apple's [permission instructions](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac).
5. Click the LevelUp icon in the menu bar and choose **Start LevelUp**. The app asks for confirmation because its tap temporarily mutes original application playback while routing it through LevelUp.

The system-audio permission is per user/Mac. Each person installing the app must approve it on their own Mac. If permission is denied or not yet granted, the app may not receive audio; silent buffers alone do not establish the permission state.

### Choose a mode

The popover starts in **Bypass** mode by default.

| Mode     | Threshold |    Ratio |   Attack |  Release |   Makeup | Limiter ceiling | Limiter release |
| -------- | --------: | -------: | -------: | -------: | -------: | --------------: | --------------: |
| Bypass   |         — |        — |        — |        — |        — |               — |               — |
| Gentle   |  −18 dBFS |    1.5:1 |    30 ms |   180 ms |    +2 dB |         −1 dBFS |           80 ms |
| Balanced |  −24 dBFS |      4:1 |    12 ms |   120 ms |    +4 dB |         −1 dBFS |           80 ms |
| Strong   |  −30 dBFS |      6:1 |     5 ms |    80 ms |    +6 dB |         −1 dBFS |           80 ms |
| Custom   |  User-set | User-set | User-set | User-set | User-set |        User-set |        User-set |

Bypass copies the input samples directly as a reference mode. The three presets use stereo-linked compressor detection and a sample-peak limiter after compressor makeup gain. Custom mode exposes threshold, ratio, attack, release, makeup gain, limiter ceiling, and limiter release. The UI stages Custom edits; choose **Apply Changes** to stop cleanly and restart the route with the new settings. Cancelling or stopping before applying leaves the active engine configuration alone.

The controls accept threshold −60 to 0 dBFS, ratio 1:1 to 20:1, attack 0.1 to 2,000 ms, compressor release 1 to 5,000 ms, makeup gain 0 to +24 dB, limiter ceiling −12 to 0 dBFS, and limiter release 1 to 5,000 ms.

Choose **Stop LevelUp** before quitting or uninstalling. Stopping allows Core Audio resources to be released in order and restores ordinary playback. If cleanup fails, the app shows the failed operation/status and log location and offers **Retry Cleanup**; do not start a second route while cleanup is incomplete. If you choose Quit while cleanup is pending, LevelUp keeps Quit pending and offers **Retry Cleanup to Quit**. It terminates only after the required route and listener cleanup succeeds.

### Output changes and Bluetooth recovery

LevelUp follows the macOS default output device. When macOS changes the default, the selected device disconnects, or it reconnects and becomes the default, LevelUp stops and cleans up the old route before resolving and validating the latest default. It waits for the output identity to settle, then creates a fresh route. Repeated device notifications are coalesced, and stale events from an earlier route are ignored.

Recovery is bounded. If the output is temporarily unavailable, LevelUp waits and retries a limited number of times. If automatic recovery is exhausted, the popover reports **Recovery failed** and offers **Retry Recovery**. If Core Audio does not confirm cleanup, LevelUp retains the required ownership, blocks new routes, and offers **Retry Cleanup**. A disconnected physical device's listener is retired only when Core Audio reports that its object is invalid and the current device list confirms that the device is absent. A device reconnecting without becoming the macOS default does not cause LevelUp to switch to it.

Bluetooth-to-built-in-speaker switching in both directions, normal playback, and Bluetooth headset disconnection have been manually validated by the maintainer on the current implementation. This validation does not guarantee that every device, driver, or macOS configuration will behave identically.

## Architecture

### Audio route

The app validates the current default output device, its UID, and its Float32 output format before creating a tap. It resolves its own Core Audio process object, creates a private stereo global process tap excluding LevelUp itself, and configures the tap's mute behavior for routing. A private aggregate device combines that tap with the selected physical output. The aggregate uses tap auto-start and drift compensation.

LevelUp registers an IOProc on the aggregate device. A callback context containing the DSP processor and preallocated audio metrics is created before the IOProc starts. The callback reads tap input, copies samples in Bypass or runs the compressor and limiter, writes aggregate output, and records numeric callback metrics. UI updates, synchronous Core Audio property queries, and diagnostic logging are kept out of the audio callback. DSP settings are staged on the UI side and applied by stopping and recreating the engine with a new configuration.

The interface runs on the main actor. Startup, stop, cleanup, and synchronous output-device checks use a serialized control queue. Core Audio listeners and the periodic route monitor feed one recovery path. Recovery checks the current default output, waits for two stable validated snapshots, then creates a fresh route. Cleanup is ordered: stop IOProc, destroy IOProc, destroy aggregate, then destroy process tap. Callback-owned memory and dependent resources are retained until Core Audio confirms that the IOProc is destroyed. Listener registrations are retained for retry when removal is unresolved. Duplicate starts are prevented while starting, stopping, recovering, or retrying cleanup.

### Project layout

| Path                                 | Purpose                                                                                                                                                                       |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/SystemAudioPassThrough/`    | SwiftUI/AppKit menu-bar app, Core Audio engine, diagnostic CLI entry point                                                                                                    |
| `Sources/LevelUpDSP/`                | Standalone Swift compressor and limiter implementation                                                                                                                        |
| `Sources/AudioMetrics/`              | Small C helper for callback timing, peaks, and silence metrics                                                                                                                |
| `Sources/PrototypeSupport/`          | Argument parsing and testable startup, cleanup, and session state helpers                                                                                                     |
| `Tests/SystemAudioPassThroughTests/` | DSP and callback metrics; startup and argument handling; cleanup and listener lifecycle; output selection and recovery policy; callback watchdog; and session lifecycle tests |
| `Assets/LevelUp-Icon-Source.png`     | Supplied Liquid Glass app icon artwork                                                                                                                                        |
| `Assets/LevelUpMenuBarIcon.png`      | Cropped logo image used by the menu-bar control and popover header                                                                                                            |
| `scripts/build-icon.sh`              | Generates and validates the multi-resolution `.icns` app icon                                                                                                                 |
| `scripts/build-app.sh`               | Builds the ARM64 app bundle, embeds its icon, and ad-hoc signs it                                                                                                             |
| `scripts/release-dmg.sh`             | Runs tests, verifies the bundle, and creates a versioned DMG such as `release/LevelUp-v0.2.2.dmg`                                                                             |

The most recently reported complete test run passed all 95 tests.

The implementation uses Swift, SwiftUI, AppKit, Core Audio, Accelerate/vDSP, and a small C metrics helper. It has no third-party package dependencies.

## Build and test from source

Use a Mac with Xcode Command Line Tools/SwiftPM installed. The app target is ARM64-only and targets macOS 14.4 or later.

Run the test suite and build the development app bundle:

```sh
swift test --triple arm64-apple-macosx14.4
scripts/build-app.sh
```

The app bundle is written to `.build/LevelUp.app`. It has bundle identifier `com.levelup.prototype.system-audio-passthrough` and executable `SystemAudioPassThrough`. To open it locally:

```sh
open -a "$PWD/.build/LevelUp.app"
```

Build the free distributable image (runs tests and bundle/signature checks as part of the workflow):

```sh
scripts/release-dmg.sh
```

With the current app version, the output is `release/LevelUp-v0.2.2.dmg`; the release script derives the name from the app version and refuses to overwrite an existing artifact. `.build/` and `release/` are ignored by Git. The app uses an **ad-hoc signature only**. This is not Developer ID signing or notarization, and no paid signing service is used. The build scripts do not disable Gatekeeper, change system audio settings, or publish/upload anything.

## CLI diagnostics

The bundled executable also supports the existing controlled diagnostic route. This is intended for development/debugging rather than everyday use. It requires an explicit acknowledgement because the tap can mute original app audio while active:

```sh
open -a "$PWD/.build/LevelUp.app" --args \
  --i-understand-system-audio-will-be-muted \
  --launch-method=launchservices \
  --log-path=/private/tmp/levelup-dsp-bypass.log \
  --dsp-mode=bypass
```

`--dsp-mode` accepts `bypass`, `gentle`, `balanced`, or `strong`. The CLI has a 30-second startup deadline, callback watchdog, output-device monitoring, and ordered cleanup. It logs diagnostics to the requested `--log-path`; do not post logs publicly without removing usernames and other personal paths.

## Privacy and safety

- Audio is processed locally and passed to the physical output. LevelUp has no recording/export feature and does not transmit audio.
- No telemetry, networking, account system, auto-updater, login item, virtual driver, or persistent audio-setting changes are included.
- The tap may mute original app output while LevelUp is routing. Start audio first; stop LevelUp to restore normal playback.
- The callback watchdog allows up to eight seconds for initial callback progress. Once callbacks begin, five seconds without progress triggers recovery. It uses monotonic timing and route-generation validation, then rechecks callback progress before teardown. Automated tests cover both timeout paths. Manual diagnostics observed a wake route begin producing callbacks after approximately six seconds; neither watchdog timeout failure path was deliberately exercised on hardware. A successful `AudioDeviceStart` return by itself is not proof that callbacks are running.
- LevelUp also monitors the selected output and attempts conservative recovery after route changes. It reports an error if bounded recovery is exhausted.
- Do not force-quit the app while routing. Normal Stop/Quit gives the engine an opportunity to release Core Audio objects safely.

## Known limitations

- **Rare startup callback failure was observed in earlier testing:** one of 10 earlier lifecycle attempts returned success from `AudioDeviceStart` but the aggregate stayed inactive and delivered no callbacks; cleanup succeeded. A later 10-cycle test completed successfully, and the current recovery implementation has since received manual device-switch and disconnection testing. The original no-callback condition has not been conclusively reproduced or proven impossible. If it happens, LevelUp's watchdog stops and cleans up the route; zero callbacks alone do not establish permission denial or a Core Audio defect.
- **Requires active audio at startup:** the aggregate may wait for the process tap to receive audio. Start playback in another app before starting LevelUp.
- **Sample-peak limiting only:** the limiter has no lookahead and does not guarantee true-peak limiting. LevelUp is not a complete loudness equalizer or broadcast loudness processor.
- **Sleep/wake recovery:** Across two reviewed diagnostic logs, ten sleep/wake cycles were observed: eight cycles with running intent recovered automatically, and two stopped-intent cycles correctly remained stopped. A later log confirmed successful routing through bluetooth headset. Bluetooth switching and disconnection were manually exercised, but the logs do not independently establish Bluetooth reconnection timing. No overlapping routes, failed sleep cleanups, or unbounded recovery loops were identified in the reviewed traces. Pre-sleep cleanup is best-effort because asynchronous Core Audio work is not guaranteed to finish before physical suspension. If cleanup remains incomplete after wake, LevelUp blocks a replacement route and offers **Retry Cleanup**. These results do not guarantee recovery with every device or macOS configuration.
- **No Intel support:** only Apple Silicon builds are produced.
- **Unnotarized distribution:** Gatekeeper may require a one-app approval on first launch, as described above.

## Transparency and license

**LevelUp is a vibe-coded app.** It was developed iteratively with AI coding assistance from human direction and review. The project includes automated tests and manual listening/lifecycle validation, but AI-assisted development does not guarantee correctness; the limitations above remain relevant. Contributions and independent review are welcome.

LevelUp is licensed under the [MIT License](LICENSE).

## Reporting an issue

Use the repository's GitHub Issues page to report a reproducible problem. Include your macOS version, Mac model/chip, LevelUp version, selected mode, what you expected, what happened, and steps to reproduce. Relevant log excerpts can help; redact usernames, local paths, and other personal information. Do not attach audio recordings.

## Uninstall

Stop routing from the LevelUp popover, choose **Quit**, then move `LevelUp.app` from Applications to Trash. No driver or background service needs to be removed.
