# Stremio iOS Enhanced (unofficial)

An unofficial, source-auditable player-enhancement layer for a personal
Stremio iOS sideload. It adds forced portrait/landscape rotation, exposes
native Picture in Picture, starts PiP automatically when returning to the Home
Screen, and keeps KSPlayer's moving-video PiP path active.

This project is not affiliated with, endorsed by, or maintained by Stremio.
It is a patch layer—not a source-code fork of the Stremio application. This
repository does **not** contain or redistribute Stremio IPAs, application
binaries, signing certificates, provisioning profiles, credentials, device
identifiers, logs, or user data. Supply an upstream IPA separately and make
sure you have the right to use it.

This repository records the verified personal-install procedure for Stremio's
official, fully featured native iOS IPA. The IPA stays local and is ignored by
Git. No Apple ID, Stremio credential, device identifier, signing certificate,
or provisioning profile belongs in this repository.

## Repository contents

- `enhancer/StremioPlayerEnhancer.m`: the Objective-C runtime extension.
- `enhancer/build.sh`: reproducible arm64 device-dylib build.
- `enhancer/package-ipa.sh`: checksum-pinned local IPA packager.
- `enhancer/simulator/`: simulator-only behavior harness.
- `CHECKSUMS.sha256`: hashes for known upstream and locally generated packages;
  the referenced binaries themselves remain ignored.

## Verified release

- Source: <https://dl.strem.io/apple/2.0.3b18/ios/stremio_iOS.ipa>
- Version: `2.0.3` (`18`)
- Original bundle identifier: `com.stremio.pal`
- Minimum iOS: `13.0`
- Architecture: `arm64`
- Size: `76,228,970` bytes
- SHA-256: `f23c50e52756d90573c3328d7f5bb2bc5930b1fe478bf7318013d83a80cfd37a`

The package inspected on 2026-07-17 was intentionally unsigned and contained
the native Stremio Swift core, its local Node streaming service, FFmpeg,
MobileVLCKit, KSPlayer, BitTorrent handling, subtitles, PiP, AirPlay, and native
download code.

## Re-download and verify

Download the release to `artifacts/stremio_iOS-2.0.3-18.ipa`, then verify it
before opening it in a sideloading tool:

```sh
curl -fL 'https://dl.strem.io/apple/2.0.3b18/ios/stremio_iOS.ipa' \
  -o artifacts/stremio_iOS-2.0.3-18.ipa
shasum -a 256 -c CHECKSUMS.sha256
stat -f '%z bytes' artifacts/stremio_iOS-2.0.3-18.ipa
```

Stop if the hash, size, version, or build differs. A newer documented Stremio
release should receive its own filename and checksum instead of silently
replacing this record.

## Initial iPhone setup

1. Install Sideloadly only from <https://sideloadly.io/>. The vendor's current
   `0.60` macOS download inspected on 2026-07-17 had SHA-256
   `428d062af1ca819712fb12cb0ace25fa49c80d9735c73cda3cbaf09ffcd63212`.
   Its DMG checksum was valid, but `Sideloadly.app` itself was an unsigned
   Intel-only application, so macOS could not verify a developer identity.
   Proceed past Gatekeeper only after explicitly accepting that limitation.
2. Connect the iPhone to this Mac by USB, unlock it, and choose **Trust** when
   prompted.
3. In Finder, select the iPhone and enable **Show this iPhone when on Wi-Fi**,
   then apply/sync the setting.
4. On iOS 16 or newer, enable **Settings > Privacy & Security > Developer
   Mode**, restart when requested, and confirm Developer Mode after restart.
5. Open the verified IPA in Sideloadly and select the intended iPhone.
6. Use the same Apple ID and generated bundle identifier for every install and
   refresh. Leave tweak injection and binary modification disabled for the
   unmodified official install.
7. Enable **Automatic Refresh**, sign in with the Apple ID through Sideloadly,
   complete two-factor authentication, and install.
8. If iOS requests it, trust the developer profile under **Settings > General >
   VPN & Device Management**.
9. Launch Stremio and sign in using the existing Stremio email/password account.
   Sign in with Apple and Handoff are unavailable in this sideloadable build.

Sideloadly's daemon and the Mac must periodically be running while the iPhone
is connected by USB or visible on the same Wi-Fi network. A free Apple signing
profile expires after seven days if it is not refreshed.

In the tested configuration, Sideloadly registered Stremio as a recurring install
(`one_off = 0`) with a seven-day signing lifetime and a refresh target of 96
hours. That renews the app after roughly four days and leaves a three-day safety
margin. The per-user `io.sideloadly.daemon` launch agent is set to `RunAtLoad`,
so it starts after Mac login; do not manually edit its installation database.

## Device verification checklist

- [ ] Cold launch and relaunch preserve the Stremio login.
- [ ] Account library, progress, and installed add-ons synchronize.
- [ ] Search, catalogs, details, and add-on stream results load.
- [ ] The bundled local streaming server reports online.
- [ ] A legal public-domain HTTPS/HLS source plays, pauses, seeks, rotates, and
      resumes.
- [ ] A legal public-domain torrent discovers peers, buffers, plays, seeks,
      stops, and resumes.
- [ ] Embedded/add-on subtitles and audio tracks can be selected and adjusted.
- [ ] Native playback, background behavior, Picture in Picture, and AirPlay are
      exercised where the device/player supports them.
- [ ] External-player fallback opens VLC when VLC is installed.
- [ ] A sustained direct stream and torrent stream remain stable.
- [ ] A same-identity Wi-Fi re-sign preserves login, library, settings, and app
      data.
- [ ] Sideloadly Daemon lists the app for automatic refresh.

Use legal test media and user-selected add-ons only. Paid Stremio Supporter
features remain account-gated and must not be bypassed. Remote APNs push,
Handoff, Sign in with Apple, and in-app purchases are not acceptance criteria
for this free sideload.

## Updating later

Obtain a newer IPA only from Stremio's official CDN or an official Stremio
release announcement. Verify and record its version, build, size, and SHA-256,
then install it through Sideloadly using the same Apple ID and generated bundle
identifier so the existing app container is retained.

## Optional player enhancer

`enhancer/StremioPlayerEnhancer.m` is a small, source-auditable native extension
for this personal sideload. It does three things:

- Adds a **Rotate video** button to Stremio's existing player-control stack. On
  iOS 16 and newer it requests a portrait or landscape scene geometry directly,
  so the button works even when the iPhone's sensor-based Rotation Lock is on.
- Exposes Stremio's native **Picture in Picture** button and keeps its existing
  `PlayerManagerPiP` action, restoration, audio-session, and playback-progress
  lifecycle intact. When a playing video enters the background because the user
  returns to the Home Screen, the enhancer requests PiP automatically. Merely
  opening Control Centre or another temporary system overlay does not trigger it.
  The enhancer first hooks KSPlayer's concrete
  `KSPictureInPictureController` subclass and AVKit's base start path. Stremio
  2.0.3 does not invoke KSPlayer's PiP configuration itself, so V7 calls the
  bundled KSMEPlayer `configPIP()` method and starts the resulting concrete
  controller through KSPlayer's own `start(layer:)` method. That retains the
  `KSComplexPlayerLayer` delegate and its display-layer frame routing, instead
  of attaching only KSMEPlayer's audio/playback delegate to a separate AVKit
  controller. V6's separate controller could start system PiP but produced
  moving audio over a frozen video frame. The generic AVKit construction and
  the app's manager action remain compatibility fallbacks if the exact bundled
  KSPlayer entry points are unavailable.
- Selects Stremio's bundled, hardware-accelerated KSPlayer backend and enables
  its sample-buffer PiP path. MobileVLCKit remains available as a compatibility
  fallback under **Settings > Apps > Stremio > Use VLCKit**, but native PiP is
  unavailable while that backend is selected. Stremio labels its third AVPlayer
  backend as deprecated.

Build the arm64 dylib with the installed iPhoneOS SDK:

```sh
./enhancer/build.sh
```

The output is `artifacts/StremioPlayerEnhancer.dylib`, which is intentionally
ignored by Git. In Sideloadly, load the verified official IPA, open Advanced
Options, add that dylib to **Tweak Injection**, and reinstall with the exact same
Apple ID and generated bundle ID as the existing app. Sideloadly will sign both
the app and dylib and cache the injection for automatic refresh. Do not enable
Cydia Substrate, Substitute, Sideload Spoofer, or unrelated tweaks.

The current V7 arm64 device build has SHA-256
`dfa6a4de7d89eb1378ccec2c9c5bf4e5c38048f3b4fe607cbd90d8e110b0e5cb`.
It targets iOS 13.0 or newer and passes ad-hoc signature verification. Replace
the previously cached enhancer dylib with this exact file before reinstalling.

### Reusable V7 IPA

Build an unsigned IPA with V7 already injected:

```sh
./enhancer/package-ipa.sh
```

With no arguments, the script accepts only the recorded official `2.0.3 (18)`
IPA and exact V7 dylib checksums. A newly inspected upstream IPA can be supplied
without weakening checksum verification:

```sh
./enhancer/package-ipa.sh \
  /path/to/upstream.ipa \
  artifacts/Stremio-V7-PiP.ipa \
  EXPECTED_UPSTREAM_SHA256
```

Before injecting, the script verifies the bundle identity and all Stremio and
KSPlayer runtime entry points used by V7. It copies the enhancer into the app's
`Frameworks` directory, adds one `LC_LOAD_DYLIB` command to Stremio's arm64
executable, records the enhancer version plus source and enhancer checksums in
`Info.plist`, and leaves the package unsigned. It does not include an Apple
certificate, provisioning profile, Apple ID, device identifier, or Stremio
credentials.

The output is `artifacts/Stremio-2.0.3-18-V7-PiP.ipa`:

- Size: `76,286,741` bytes
- SHA-256: `ce3d965e8ac2e834fba05bf117cada25657b4a3d1e21c27d905f38f31701f5c6`
- Upstream bundle/version: `com.stremio.pal`, `2.0.3 (18)`
- Embedded enhancer: V7,
  `dfa6a4de7d89eb1378ccec2c9c5bf4e5c38048f3b4fe607cbd90d8e110b0e5cb`

Open this pre-injected IPA directly in Sideloadly and sign it with the same
Apple ID and generated bundle identity used for the existing installation.
Leave Sideloadly's **Tweak Injection** list empty for this IPA because the V7
dylib and load command are already present. Do not delete the installed app
first if retaining its container data is required.

Because this is a modified personal sideload, re-check it after every upstream
Stremio update. If the app fails to launch, reinstall the official IPA without
the dylib using the same identity; the extension does not modify Stremio account
data or bypass paid features.

### Simulator verification

The official 2.0.3 app and its player frameworks are built for the physical iOS
platform, not the iOS Simulator platform. The iOS 26.5 Simulator accepts the
bundle registration but SpringBoard refuses to launch it. Use the included
simulator harness to test the same enhancer source against mock Stremio runtime
classes instead:

```sh
./enhancer/simulator/build.sh
```

This verifies dylib loading, the concrete KSPlayer PiP-subclass capture, the
KSPlayer `configPIP()` and `start(layer:)` Swift ABI bridge, the
background/foreground render handoff, KSPlayer and sample-buffer PiP preferences,
PiP/rotation button insertion, manual and background PiP action dispatch,
duplicate-background suppression, runtime hooks, and the scene-geometry
rotation request. Real Stremio video, KSPlayer decoding, system PiP
presentation, torrent playback, and AirPlay must still be checked on the iPhone
because those components cannot run in this simulator build.

## License and trademarks

The original code in this repository is available under the MIT License. The
Stremio application, Stremio name and logo, bundled player frameworks, and all
third-party components remain the property of their respective owners and are
not covered by this repository's license.
