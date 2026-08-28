# Building the iOS app

The current release target is **Bunny** for iPhone and iPad on iOS 16 or newer.
It uses the public Stremio add-on protocol but does not ship media, a catalog of
its own, or a torrent engine.

Bunny uses AVFoundation for Apple-native sources and the project's Rust media
core for direct Matroska and WebM. A streaming server you configure can resolve
torrents or provide HLS for codecs Apple does not decode.

The repository also contains tvOS and standalone watchOS targets. They are not
part of the current iOS release pass.

## First build

Install Xcode, XcodeGen 2.42 or newer, and Rust 1.95.0:

~~~sh
brew install xcodegen rust
./scripts/test.sh
./scripts/dev-workflow.sh build-bunny-simulator
open StremioSkeleton.xcodeproj
~~~

project.yml owns the target graph, bundle metadata, and build settings. Do not
edit the generated Xcode project. Regenerate it after changing the spec:

~~~sh
xcodegen generate --spec project.yml
~~~

The iOS targets have no Swift package dependencies. The Rust crate has no
third-party Cargo packages. Its architecture, support matrix, and limits are in
[docs/RUST_MEDIA_CORE.md](docs/RUST_MEDIA_CORE.md).

## Everyday commands

~~~sh
./scripts/test.sh
./scripts/dev-workflow.sh build-bunny-simulator
./scripts/e2e-simulator.sh
./scripts/ui-state-screenshots.sh
./scripts/benchmark-rust-media-core.sh
SKELETON_PUBLIC_RELEASE=1 ./scripts/dev-workflow.sh build-bunny-device
~~~

The materialized workflow copies the current source into a verified local
workspace under /private/tmp, hashes the inputs, and records artifact
provenance. This avoids File Provider placeholders becoming hidden build
inputs.

## Add-ons and large streams

Cinemeta supplies the default metadata catalog. Add another provider by
entering its full HTTPS manifest URL in the Add-ons screen. Account traffic and
remote manifests must use HTTPS. Plain HTTP is reserved for loopback or a
private-network streaming server.

File size does not remove provider results. Entries at 40 GB, above 50 GB, and
in TB remain in the list when an add-on returns them. "Current" keeps the
existing quality order. "Big files" sorts each cached or uncached group from
largest to smallest, with cached streams first in both modes. The first 60
results appear immediately. Use "Show more streams" for later batches.

Direct HTTPS video and HLS can play without a local service. Torrent and magnet
results remain visible but need a compatible server configured in Settings.
Keep provider credentials and temporary stream tokens out of source, fixtures,
screenshots, and issue reports.

## Watch Together source

Backend/watch-together/ remains as optional development source. The iOS targets
compile a disabled local stub and do not link Convex, LiveKit, WebRTC, or
SwiftProtobuf. The backend is not part of the Bunny IPA.

## Device IPA

~~~sh
SKELETON_PUBLIC_RELEASE=1 ./scripts/dev-workflow.sh build-bunny-device
~~~

The artifact is build/Bunny-device.ipa inside the materialized workspace. It
contains an arm64 Bunny app with an ad hoc signature and the standard Payload/
layout. A local signing tool must provision it for the destination device.

Use a bundle identifier owned by the release team for TestFlight or the App
Store. Keep Apple credentials, private keys, certificates, profiles, device
receipts, and export settings outside the repository.

The root [release guide](../docs/RELEASING.md) separates source, IPA, device,
TestFlight, App Review, and publication evidence.

## Licensing

Original repository code is MIT licensed. The current iOS binary does not link
KSPlayer, FFmpegKit, FFmpeg, MobileVLCKit, Convex, or LiveKit. It bundles the
root license and the exact Rust 1.95.0 standard-library notice. Read
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and inspect the finished app
before distribution.
