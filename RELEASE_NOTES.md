# LevelUp v0.2.2

**Status:** Published as a stable release on [GitHub](https://github.com/prajvalhl/levelup/releases/tag/v0.2.2). Download [LevelUp-v0.2.2.dmg](https://github.com/prajvalhl/levelup/releases/download/v0.2.2/LevelUp-v0.2.2.dmg) (build 4).

This release adds automatic recovery from macOS sleep and wake, improves callback startup and stall detection, and brings the LevelUp logo into the popover header. The existing icon-only menu-bar branding was introduced in v0.2.1 and is not new in this release.

## What’s new

- LevelUp responds to macOS sleep and wake notifications. If audio was running before sleep, it cleans up the old route and automatically resolves and starts a fresh route after wake. A session that was stopped remains stopped.
- Recovery waits for required Core Audio cleanup before starting a replacement route. Route generations and listener tokens reject stale events, helping prevent overlapping or duplicate routes.
- Bluetooth outputs can recover when they become available and are the current macOS default. Reconnection timing depends on the headset and macOS, and recovery is not guaranteed for every device or setup.
- The popover header now displays the custom LevelUp logo used for the existing menu-bar branding. If the logo resource is missing or cannot be decoded, LevelUp logs the issue and displays the original waveform symbol.

## Reliability and validation

- The callback watchdog allows up to eight seconds for initial callback progress. After callbacks begin, five seconds without progress triggers a recovery attempt. It uses monotonic timing, checks the route generation, and rechecks callback progress before teardown.
- Automated tests cover both callback timeout paths. Neither timeout failure path was deliberately triggered during hardware testing. One reviewed wake route began producing callbacks after approximately six seconds and continued normally.
- The latest reported validation passed all 95 automated tests. The ARM64 app build and strict code-signature verification succeeded. The build uses an ad-hoc signature; it is not Developer ID signed or notarized.
- Across two reviewed runtime logs, ten sleep/wake cycles were observed: eight running-intent sessions recovered automatically, while two stopped-intent sessions remained stopped. No overlapping routes, failed sleep cleanups, or unbounded recovery loops were identified in those traces.
- A reviewed log confirmed successful routing through realme Buds Wireless 3. Bluetooth switching and disconnection were manually exercised, but the logs do not independently establish Bluetooth reconnection timing.

## Requirements and installation

- Apple Silicon Mac (ARM64 only).
- macOS 14.4 or later.
- Each user must grant LevelUp system-audio capture permission on their Mac.
- The free build is ad-hoc signed and not notarized. macOS may require per-app approval in **System Settings → Privacy & Security**. Do not disable Gatekeeper globally.

See [README.md](README.md) for installation, privacy, architecture, and troubleshooting details.

## Known limitations

- Pre-sleep cleanup is best-effort because asynchronous Core Audio cleanup is not guaranteed to finish before macOS suspends the app. If cleanup remains incomplete after wake, LevelUp blocks a replacement route until cleanup succeeds.
- Bluetooth reconnection timing varies, and audio-device or driver behavior is not guaranteed across every hardware configuration.
- A no-callback startup condition occurred once in earlier lifecycle testing even though `AudioDeviceStart` returned success. Later lifecycle tests passed, but the original condition has not been conclusively proven impossible. The watchdog has automated coverage for bounded recovery; its timeout failure paths were not deliberately triggered on hardware.
- The limiter is sample-peak based, has no lookahead, and does not guarantee true-peak limiting.

## Transparency

LevelUp is a vibe-coded project developed with AI coding assistance under human direction and review. Audio processing stays local; LevelUp does not record or transmit audio.

---

# LevelUp v0.2.1 — Apple Silicon Preview

This release adds custom icon-only menu-bar branding. The cropped transparent PNG is bundled with the app and rendered as a template image so macOS can adapt it to light and dark menu-bar appearances. The existing application icon is unchanged.

- Improved popover dismissal when clicking elsewhere in the menu bar.

## Requirements and installation

- Apple Silicon Mac (ARM64 only).
- macOS 14.4 or later.
- Each user must grant LevelUp system-audio capture permission on their Mac.
- This free build is ad-hoc signed and is not Developer ID signed or notarized. macOS may require per-app approval in **System Settings → Privacy & Security**. Do not disable Gatekeeper globally.

See [README.md](README.md) for installation, privacy, architecture, and troubleshooting details.

## Known limitations

- A no-callback startup condition occurred once in earlier lifecycle testing even though `AudioDeviceStart` returned success. A later 10-cycle test passed, and subsequent device recovery was manually exercised, but the original condition has not been conclusively proven impossible.
- Recovery from sleep/wake is not implemented.
- The limiter is sample-peak based, has no lookahead, and does not guarantee true-peak limiting.
- Device/driver behavior can vary; the manual Bluetooth tests do not guarantee compatibility with every audio device or macOS setup.

## Transparency

LevelUp is a vibe-coded project developed with AI coding assistance under human direction and review. Audio processing stays local; LevelUp does not record or transmit audio.

---

# LevelUp v0.2.0 — Apple Silicon Preview

This release candidate improves output-device recovery and cleanup reliability.

## What changed

- LevelUp follows the current macOS default output and rebuilds its route after a default-output change or physical output disconnection.
- Recovery validates the latest output, waits for stable device snapshots, uses bounded retries, and ignores stale listener events.
- Bluetooth switching to and from the built-in speakers, playback, and headset disconnection were manually validated by the maintainer on the current implementation.
- Cleanup now handles a vanished physical device listener conservatively: it retires that registration only after Core Audio reports an invalid object and the system device list confirms the physical device is absent.
- System listener cleanup remains retryable. Quit stays pending while cleanup is incomplete and completes only after cleanup succeeds.
- The ad-hoc release script produces a versioned DMG and refuses to overwrite an existing artifact.

## Requirements and installation

- Apple Silicon Mac (ARM64 only).
- macOS 14.4 or later.
- Each user must grant LevelUp system-audio capture permission on their Mac.
- This free build is ad-hoc signed and is not Developer ID signed or notarized. macOS may require per-app approval in **System Settings → Privacy & Security**. Do not disable Gatekeeper globally.

See [README.md](README.md) for installation, privacy, architecture, and troubleshooting details.

## Known limitations

- A no-callback startup condition occurred once in earlier lifecycle testing even though `AudioDeviceStart` returned success. A later 10-cycle test passed, and subsequent device recovery was manually exercised, but the original condition has not been conclusively proven impossible.
- Recovery from sleep/wake is not implemented.
- The limiter is sample-peak based, has no lookahead, and does not guarantee true-peak limiting.
- Device/driver behavior can vary; the manual Bluetooth tests do not guarantee compatibility with every audio device or macOS setup.

## Transparency

LevelUp is a vibe-coded project developed with AI coding assistance under human direction and review. Audio processing stays local; LevelUp does not record or transmit audio.
