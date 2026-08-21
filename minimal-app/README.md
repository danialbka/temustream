# Skeleton — minimal Stremio-compatible iOS client

Skeleton is a clean-room SwiftUI client for the public Stremio add-on protocol.
It keeps the useful product shape while removing the bundled Node runtime,
analytics/crash SDKs, MobileVLCKit, and unrelated services. Torrent work stays
outside the IPA behind a small compatible server interface. Playback uses the
same default engine family as Stremio iOS: KSPlayer with its FFmpeg-backed media
engine for direct files, HLS, uncommon containers/codecs, and torrent range URLs.

## Included

- add-on manifest validation and installation
- Cinemeta / Letterboxd Recommendations source dropdown
- catalog browsing, search, and protocol-native infinite scrolling
- metadata/details
- direct HTTP/HLS stream discovery
- torrent/magnet stream resolution through a compatible localhost, LAN, or
  HTTPS streaming server
- KSPlayer controls with Picture in Picture, AirPlay, audio/subtitle tracks,
  aspect fit/fill, seeking, and playback speed
- one KSPlayer/FFmpeg playback path for MP4, HLS, MKV, AV1, FLAC, TrueHD, DTS,
  and torrent sources
- automatic server-side HLS remux/transcode as a secondary fallback, including
  VideoToolbox profile discovery
- observable playback startup with automatic fallback, timeout, retry, and a
  useful failure state instead of a permanent black player
- local library persistence
- Stremio email/password sign-in with the session token stored in iOS Keychain
  on signed devices and protected app storage in the entitlement-free simulator build
- Stremio library/removal and installed add-on synchronization
- unit and integration tests
- deterministic simulator E2E flow through manifest, catalog, details, stream,
  real H.264/AAC direct and torrent-route playback startup, library persistence,
  account login/pull/push contracts, and session save/load/delete persistence

## Deliberately omitted

- a second bundled compatibility engine such as MobileVLCKit
- an embedded torrent engine; connect a compatible service at the default
  `http://127.0.0.1:11470` or enter a private-LAN/HTTPS server URL
- telemetry, ads, push, Firebase, and crash reporting
- DRM bypasses or paid-feature bypasses

Torrent sources remain visible when the configured service is offline and show
an actionable playback error. External links are handed to iOS.

KSPlayer is distributed under GPL-3.0. Keep this client and any distributed
build compliant with that license, or replace the dependency with a separately
licensed decoder before closed-source distribution.

## Workflows

```sh
./scripts/test.sh
./scripts/build-simulator.sh
./scripts/build-device.sh
./scripts/benchmark-player-footprint.sh
./scripts/benchmark-catalog-paging.sh
./scripts/e2e-simulator.sh
./scripts/ui-state-screenshots.sh
./scripts/verify.sh
```

`verify.sh` is the single local quality gate. The matching GitHub Actions
workflow runs the same unit, build, footprint, and simulator E2E sequence and
uploads the signed ad-hoc packages plus E2E and 13-state UI screenshots as
workflow artifacts. See `UI_STATE_MATRIX.md` for the screenshot inventory.

The normal app starts with Cinemeta and includes Stremboxd's public Letterboxd
"Popular This Week" recommendations as a catalog source. The infinite grid uses
each response's actual item count for `skip`, deduplicates repeated pages, and
stops when an add-on returns an empty or repeated page. Posters are fit inside
their cards without cropping. Install additional lawful
direct-stream or torrent add-ons from the Add-ons tab. Remote manifests and
account APIs must use HTTPS; local HTTP is limited to loopback/private-network
streaming servers and deterministic development fixtures. Use torrents only
for media you are legally permitted to access and distribute.
