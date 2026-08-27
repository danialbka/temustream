# Building TemuStremio

This directory contains the working iOS, iPadOS, tvOS, and watchOS apps. The
clients use the public Stremio add-on protocol, but they do not ship a catalog
of media or an embedded torrent engine.

The iPhone and iPad app has the broadest playback support. It can use the Bunny
player, KSPlayer, MobileVLCKit, and Apple-native playback, and it can hand
torrent or magnet sources to a streaming server you configure. The Apple TV
interface is designed for the Siri Remote. The Apple Watch app is a separate,
standalone app: it contacts add-ons itself, can sign in and synchronize its
account library and installed add-ons, and plays compatible HTTPS HLS or video
through AVPlayer. A streaming server you configure can resolve torrents or
convert incompatible HTTP(S) video to HLS. It does not require an iPhone and
does not include Watch Together.

## First build

You need a Mac with Xcode, XcodeGen 2.42 or newer, Rust, and FFmpeg. Xcode must
include the SDK for each platform you plan to build. Simulator runtimes are a
separate download in Xcode Settings under Components.

```sh
brew install xcodegen rust ffmpeg
./scripts/test.sh
./scripts/build-tvos.sh --typecheck
./scripts/build-watchos.sh --typecheck
./scripts/build-simulator.sh
open StremioSkeleton.xcodeproj
```

`project.yml` owns targets, build settings, package references, bundle metadata,
and schemes. Do not edit the generated project by hand. After changing the
spec, regenerate it with:

```sh
xcodegen generate --spec project.yml
```

The first app build fetches the checksum-pinned MobileVLCKit package. Swift
packages are pinned in `Package.resolved`; the Rust policy code lives in
`rust/StremioPlaybackCore`.

## Everyday commands

```sh
./scripts/test.sh                         # Swift and Rust unit tests
./scripts/build-simulator.sh              # iOS Simulator app and ZIP
./scripts/build-tvos.sh --typecheck       # tvOS SDK compile gate
./scripts/build-watchos.sh --typecheck    # watchOS SDK compile gate
./scripts/dev-workflow.sh build-tvos      # tvOS Simulator app, runtime required
./scripts/dev-workflow.sh build-watchos   # watchOS Simulator app, runtime required
./scripts/e2e-simulator.sh                # deterministic iOS fixture flow
./scripts/ui-state-screenshots.sh         # named UI-state captures
./scripts/verify.sh                       # complete local release gate
```

The materialized `dev-workflow.sh` path is useful when macOS File Provider has
left cloud-backed Git or Xcode files as placeholders. It copies the current
source into a verified temporary workspace and records which source and overlay
files were used.

## Using add-ons and streams

Cinemeta supplies the default metadata catalog. Add another provider from the
Add-ons screen by entering its full manifest URL. Remote manifests and account
traffic must use HTTPS; plain HTTP is reserved for loopback and private-network
streaming servers.

Direct HTTPS video and HLS can play without a local service. Torrent and magnet
results remain visible, but they need a compatible streaming server configured
in Settings. Keep private provider URLs and temporary stream tokens out of
source, fixtures, screenshots, and issue reports.

The watch has the same basic provider flow in a smaller interface. It accepts
AVPlayer-compatible HTTPS HLS, MP4, M4V, MOV, and compatible media responses.
Without a configured streaming server it rejects insecure HTTP, embedded URL
credentials, torrent-only sources, external-app links, and formats that need
conversion. With a server you control, it can resolve torrents and request HLS
for incompatible HTTP(S) video; VLC, FFmpeg, and the iPhone player stack remain
outside the watch app. See [`docs/WATCHOS.md`](docs/WATCHOS.md) for its controls
and exact limits.

## Optional Watch Together backend

Watch Together belongs to the iOS app only. Convex stores profiles,
friendships, rooms, and the latest playback snapshot; LiveKit transports
playback events, presence, and opt-in voice chat. Stream URLs and Stremio
credentials are not published to a room. Each participant resolves a playable
source independently.

The default build leaves both service endpoints blank. For local development:

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
xcodegen generate --spec project.yml
```

Keep the LiveKit API secret in the Convex deployment environment. The app gets
only public endpoints from the ignored
`config/WatchTogether.local.xcconfig`. A public deployment also needs admission
controls, request limits, quotas, cleanup, monitoring, and an abuse policy; the
sample backend does not provide all of those safeguards yet.

## Device and IPA builds

For a local sideloading handoff:

```sh
SKELETON_PUBLIC_RELEASE=1 ./scripts/build-device.sh
unzip -tq build/StremioSkeleton-device.ipa
shasum -a 256 build/StremioSkeleton-device.ipa
```

This produces an arm64 app with an ad hoc signature and the usual `Payload/`
layout. It is not an App Store build and is not installable until a sideloading
tool signs it for the destination device. Certificates, private keys,
provisioning profiles, Apple credentials, and export settings belong outside
the repository. Public-release mode cleans the app target and forces the
optional Watch Together endpoints to empty. Omit it only for an intentional
internal build that should use the ignored local backend configuration.

`fast-ota.sh` and `sideloadly-cli.sh` are machine-local convenience paths for
an already configured device. Copy
`config/sideloadly.snapshot.example.json` to the ignored local snapshot path,
or set `SIDELOADLY_SNAPSHOT`. Never commit the real snapshot: it can contain
device and signing metadata.

App Store, TestFlight, and registered-device exports require unique bundle
identifiers, an Apple Developer team, valid signing, and a fresh archive in
Xcode Organizer. The root [`docs/RELEASING.md`](../docs/RELEASING.md) keeps
those flows separate and lists the remaining legal and store-review checks.

## What a passing check proves

A unit test or successful compile is source evidence. A Simulator build adds
packaging evidence. A device IPA adds an unsigned handoff artifact. None of
those proves that a particular stream played on a physical device or that an
upload reached TestFlight or App Review.

For playback work, record direct-file, HLS, provider-stream, subtitles, audio
tracks, seeking, pause and resume, fallback, and rotation separately. On Apple
Watch, also verify the Digital Crown timeline, compact controls, and playback
without the paired iPhone app running.

The detailed architecture and command map is in
[`docs/CODEBASE_MAP.md`](docs/CODEBASE_MAP.md). The expected UI-state captures
are listed in [`UI_STATE_MATRIX.md`](UI_STATE_MATRIX.md).

## Licensing

Original repository code is MIT licensed. Dependencies keep their own terms.
KSPlayer and the selected FFmpegKit package are GPL-3.0, so distributing a
compiled IPA needs deliberate license review. MobileVLCKit and the codecs it
ships may add more obligations. Read
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) before publishing a
binary.
