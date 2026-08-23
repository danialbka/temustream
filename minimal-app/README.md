# Skeleton — minimal Stremio-compatible iOS client

Skeleton is a clean-room SwiftUI client for the public Stremio add-on protocol.
It keeps the useful product shape while removing the bundled Node runtime,
analytics/crash SDKs and unrelated services. Torrent work stays
outside the IPA behind a small compatible server interface. Playback offers
Bunny, Performance, KSPlayer, and VLC in Settings, with the custom Bunny player
as the default. AVFoundation remains an internal hardware-decoding backend for
Bunny and Performance rather than a deprecated standalone choice.

## Included

- add-on manifest validation and installation
- Cinemeta / Letterboxd Recommendations source dropdown
- catalog browsing, search, and protocol-native infinite scrolling
- metadata/details
- direct HTTP/HLS stream discovery
- torrent/magnet stream resolution through a compatible localhost, LAN, or
  HTTPS streaming server
- selectable Bunny, Performance, KSPlayer, and VLC playback paths
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
- friend profiles/codes, friend requests, and friends-only Watch Together rooms
  backed by Convex, with reliable LiveKit play/pause/seek events, reconnect
  snapshots, drift correction, room presence, and opt-in microphone voice chat
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
./scripts/fast-ota.sh doctor
./scripts/fast-ota.sh update
./scripts/sideloadly-cli.sh doctor
./scripts/sideloadly-cli.sh update
./scripts/benchmark-player-footprint.sh /path/to/reference.ipa
./scripts/benchmark-catalog-paging.sh
./scripts/e2e-simulator.sh
./scripts/ui-state-screenshots.sh
./scripts/configure-watch-together.sh
./scripts/verify.sh
```

## Watch Together development setup

The iOS app uses the official Convex Swift and LiveKit Swift clients. Convex
stores profiles, friendships, room membership, and the latest playback
snapshot. LiveKit carries reliable low-latency playback events, presence, and
audio. The app sends only the Stremio content identity and playback state; it
never publishes stream URLs, provider tokens, or Stremio credentials. Each
participant must independently have access to the same title and select a
playable stream.

Backend setup lives in `Backend/watch-together`:

```sh
cd Backend/watch-together
npm install
npx convex dev --once
npx convex env set LIVEKIT_URL 'wss://your-project.livekit.cloud'
npx convex env set LIVEKIT_API_KEY
npx convex env set LIVEKIT_API_SECRET
set -a; source .env.local; set +a; npm run probe
cd ../..
WATCH_TOGETHER_LIVEKIT_URL='wss://your-project.livekit.cloud' \
  ./scripts/configure-watch-together.sh
xcodegen generate
```

The LiveKit API secret exists only in Convex deployment environment variables.
The iOS build receives public Convex/LiveKit endpoints through the ignored
`config/WatchTogether.local.xcconfig`. Voice is off by default, microphone
permission is requested only after the in-player mic button is tapped, and
leaving a room unpublishes and stops the local microphone track.

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

`fast-ota.sh update` is the normal configured-device update path. It checks the
CoreDevice Wi-Fi tunnel before building, signs locally with the current
Sideloadly certificate and provisioning profile inside a disposable keychain,
installs the `.app` directly with `devicectl`, verifies and launches the exact
build, then stages the source IPA in Sideloadly AutoRefresh without running a
second install. Its signing profile remains in a mode-600 application-support
cache; credentials and private keys are never copied into the repository.
Use `--skip-build` to reinstall an already-built IPA. Run the full
`sideloadly-cli.sh update` only when `fast-ota.sh doctor` reports that the
seven-day profile needs renewal.

`sideloadly-cli.sh update` is the full configured-device renewal path. It is
the slower fallback: it builds the device IPA, validates its
archive and signing data, reuses the
existing credential reference and AutoRefresh record stored by Sideloadly,
invokes Sideloadly 0.60's internal silent queue, refreshes the profile cache,
verifies the installed version with
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
