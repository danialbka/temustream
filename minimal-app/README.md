# Skeleton — minimal Stremio-compatible iOS client

Skeleton is a clean-room SwiftUI client for the public Stremio add-on protocol.
It keeps the useful product shape while removing the bundled Node runtime,
analytics/crash SDKs and unrelated services. Torrent work stays
outside the IPA behind a small compatible server interface. Playback uses the
same player choices as Stremio iOS: KSPlayer, VLC, and AVPlayer, plus an
adaptive Performance mode. Each is selectable in Settings, with Performance
as the default.

## Included

- add-on manifest validation and installation
- Cinemeta / Letterboxd Recommendations source dropdown
- catalog browsing, search, and protocol-native infinite scrolling
- metadata/details
- direct HTTP/HLS stream discovery
- torrent/magnet stream resolution through a compatible localhost, LAN, or
  HTTPS streaming server
- selectable Performance, KSPlayer, VLC, and AVPlayer playback paths
- Movies and TV Series catalog selection, season-by-season episode listings,
  provider episode thumbnails with a missing-artwork fallback, per-episode resume
  state, and persistent watched ticks after completion
- a dependency-free Rust playback-policy core that routes Apple-native HLS to
  AVFoundation, relabeled/direct transport streams to hardware-backed KSPlayer,
  and HEVC or unusually large sources to VLC's native hardware-backed drawable
- a payload-signature stream bridge that detects mislabeled MP4/MPEG-TS/MKV/HLS
  responses, repairs bad TorBox file selection, waits for provider preparation,
  and retries transient network failures before opening a decoder
- a persistent Settings debug switch with an in-player overlay for measured
  FPS, nominal FPS, dropped frames/packets, stalls, buffer depth, and the active
  hardware-decoder policy
- KSPlayer controls with Picture in Picture, AirPlay, audio/subtitle tracks,
  aspect fit/fill, seeking, and playback speed
- KSPlayer/FFmpeg playback for uncommon containers and codecs, with KSPlayer's
  faster native backend used for MP4/MOV and reliable segmented HLS seeking
- automatic server-side HLS remux/transcode before AVPlayer tries unsupported
  MKV/AV1/FLAC media, including
  VideoToolbox profile discovery
- native LibVLC rendering for demanding sources, avoiding the slower custom
  memory-copy path and its decoder-shutdown race without changing the selected player
- one same-engine repair retry before cross-player fallback
- observable playback startup with automatic fallback, timeout, retry, and a
  useful failure state instead of a permanent black player
- local library persistence
- Stremio email/password sign-in with the session token stored in iOS Keychain
  on signed devices and protected app storage in unsigned simulator builds
- Stremio library/removal and installed add-on synchronization
- unit and integration tests
- deterministic simulator E2E flow through manifest, catalog, details, stream,
  real H.264/AAC direct and torrent-route playback startup, library persistence,
  account login/pull/push contracts, and session save/load/delete persistence

## Deliberately omitted

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
./scripts/sideloadly-cli.sh doctor
./scripts/sideloadly-cli.sh update
./scripts/benchmark-player-footprint.sh /path/to/reference.ipa
./scripts/benchmark-catalog-paging.sh
./scripts/e2e-simulator.sh
./scripts/ui-state-screenshots.sh
./scripts/verify.sh
```

`verify.sh` is the single local quality gate. Set `SKELETON_REFERENCE_IPA` to
include the comparative player-footprint report; the comparison is skipped
when a reference build is unavailable, such as on a clean GitHub runner. The
matching GitHub Actions workflow runs the same unit, build, and simulator E2E
sequence and uploads the signed ad-hoc packages plus E2E and 17-state UI
screenshots as workflow artifacts. See `UI_STATE_MATRIX.md` for the screenshot
inventory.
`build-device.sh` also emits `build/StremioSkeleton-device.ipa` with the
required `Payload/StremioSkeleton.app` archive layout for sideloading.
See `PLAYBACK_BENCHMARKS.md` for the strict real-stream and synthetic playback
matrix, including the proof boundary between simulator and physical-device QA.

`sideloadly-cli.sh update` is the one-command configured-device update path. It
builds the device IPA, validates its archive and signing data, reuses the
existing credential reference and AutoRefresh record stored by Sideloadly,
invokes
Sideloadly 0.60's internal silent queue, verifies the installed version with
`devicectl`, and launches the app. Copy
`config/sideloadly.snapshot.example.json` to the local snapshot path expected by
the script (or set `SIDELOADLY_SNAPSHOT`) and fill it from your own Sideloadly
record. Machine identifiers and the real snapshot stay ignored; Apple ID
credentials, sessions, certificates, and private keys remain solely in
Sideloadly's private application-support directory. Because the silent queue is
an internal interface, the script deliberately refuses to run against another
Sideloadly version until its behavior and database schema are revalidated.

The normal app starts with Cinemeta and includes Stremboxd's public Letterboxd
"Popular This Week" recommendations as a catalog source. The infinite grid uses
each response's actual item count for `skip`, deduplicates repeated pages, and
stops when an add-on returns an empty or repeated page. Posters are fit inside
their cards without cropping. Install additional lawful
direct-stream or torrent add-ons from the Add-ons tab. Remote manifests and
account APIs must use HTTPS; local HTTP is limited to loopback/private-network
streaming servers and deterministic development fixtures. Use torrents only
for media you are legally permitted to access and distribute.
