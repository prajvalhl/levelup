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
