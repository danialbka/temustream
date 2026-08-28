# Releasing Bunny for iOS

This release pass covers the Bunny iOS target only. A public source release, a
local sideloading IPA, a registered-device export, and an App Store upload are
different outputs. Test and record each one separately.

The tvOS and watchOS sources remain in the repository, but they are not release
gates for this iOS build.

## Resolve these blockers first

The source bundle identifier local.bunny.player is for development. Replace it
in minimal-app/project.yml with an identifier owned by the release team before
TestFlight or App Store submission. Keep developer teams, certificates,
provisioning profiles, authentication keys, and export settings outside Git.

The app and public documentation use the name Bunny. It still needs a normal
trademark clearance search before distribution.

The app currently defaults to Stremio-operated services:

- StremioAccountClient uses https://api.strem.io
- the default Cinemeta catalog uses a manifest on strem.io

Before public binary distribution, obtain written authorization for those
endpoints or replace them with project-controlled or separately authorized
services. Open-source code does not grant access to a hosted service.

The current iOS target has no Swift package dependencies. Its original Rust
media crate has no third-party Cargo packages, but the static library uses the
Rust standard library. Bundle the exact Rust notice from the pinned toolchain
and inspect the finished app against
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

The custom player removes KSPlayer, FFmpegKit, FFmpeg, and MobileVLCKit from the
iOS binary. It does not settle the project's MIT license, Rust notices, codec
patents, media rights, service terms, or trademarks.

An old personal device label remains reachable in repository history. Before
publishing this existing history, either approve a reviewed history rewrite
with a backup or create a clean repository from git archive. Do not rewrite or
force-push history as a routine release step.

This guide is an engineering checklist, not legal advice.

## 1. Freeze and inspect the source

From the repository root:

~~~sh
git status --short
./scripts/public-release-check.sh --history
./minimal-app/scripts/test.sh
./minimal-app/scripts/benchmark-rust-media-core.sh
SKELETON_PUBLIC_RELEASE=1 \
  ./minimal-app/scripts/dev-workflow.sh build-bunny-simulator
~~~

Read every changed and untracked source file before tagging. The scanner hides
matched credential values, but it cannot decide whether ordinary prose,
screenshots, fixtures, or benchmark notes are private.

Keep source tests in Git. Ignore generated results, coverage, logs,
screenshots, archives, provisioning files, and machine-local configuration.

Before tagging:

- update Bunny's version and build number in minimal-app/project.yml
- regenerate the project with xcodegen generate --spec project.yml
- run the Swift and Rust tests
- build and launch the Bunny simulator target
- inspect the exact device IPA and bundled notices
- confirm no package resolution file or third-party framework entered the app
- verify provider results above 40 GB remain available through the stream list
- archive a committed source state, not an unexplained dirty tree

## 2. Make a public source release

Use an annotated or signed tag. Let GitHub create its source archives, or build
one locally with git archive so ignored files cannot enter it:

~~~sh
version='vX.Y.Z'
git archive --format=tar.gz --prefix="Bunny-$version/" \
  -o "Bunny-$version.tar.gz" "$version"
shasum -a 256 "Bunny-$version.tar.gz" \
  > "Bunny-$version.tar.gz.sha256"
~~~

Attach the checksum and release notes. Do not attach .env files, signing
configuration, Xcode archives, app containers, Sideloadly snapshots, private
logs, or credentials. Enable private vulnerability reporting, secret scanning,
dependency alerts, and branch protection before announcing the repository.

## 3. Build a local Bunny IPA

The materialized build copies and hashes the current source, builds the arm64
Bunny target, applies an ad hoc signature, and creates the expected Payload/
layout:

~~~sh
cd minimal-app
SKELETON_PUBLIC_RELEASE=1 ./scripts/dev-workflow.sh build-bunny-device
~~~

The default output is:

~~~text
/private/tmp/stremio-dev-workflow/workspace/build/Bunny-device.ipa
/private/tmp/stremio-dev-workflow/workspace/build/Bunny-device.ipa.source.json
/private/tmp/stremio-dev-workflow/latest.json
~~~

A direct source-tree build is also available:

~~~sh
SKELETON_IOS_VARIANT=bunny \
SKELETON_PUBLIC_RELEASE=1 \
STREMIO_SOURCE_ID="$(git rev-parse HEAD)" \
  ./scripts/build-device.sh
~~~

Audit the handoff before signing:

~~~sh
ipa='/private/tmp/stremio-dev-workflow/workspace/build/Bunny-device.ipa'
work_dir="$(mktemp -d)"
unzip -q "$ipa" -d "$work_dir"
plutil -p "$work_dir/Payload/Bunny.app/Info.plist"
otool -L "$work_dir/Payload/Bunny.app/Bunny"
find "$work_dir/Payload/Bunny.app" -maxdepth 2 -type f -print
codesign -d --entitlements :- "$work_dir/Payload/Bunny.app"
shasum -a 256 "$ipa"
~~~

Check that the app is named Bunny, the source bundle identifier is
local.bunny.player, the version and build match project.yml, and the root
license plus Rust notice are present. The app must contain no KSPlayer, FFmpeg,
MobileVLC, Convex, LiveKit, WebRTC, or SwiftProtobuf binaries.

The resulting IPA is a sideloading handoff. It is not an App Store archive and
will not install until a signing tool provisions it for the destination
device. Keep the signed result private because provisioning data can identify
the team and device.

## 4. Install as a separate local app

Sign Bunny with a profile for its bundle identifier. After installation,
verify:

- Bunny is installed under the expected bundle identifier
- the new Home Screen label is Bunny
- Bunny's installed bundle identifier and build number match the signed result
- Bunny launches without a trust or provisioning error
- a legal direct file and HLS fixture play on the phone
- a provider list can reveal its remaining results through "Show more streams"

An installed build is not playback proof. Record physical-device playback
separately from the simulator and from the IPA audit.

## 5. Export for registered devices

Apple's registered-device flow needs an explicit App ID, an Apple Distribution
certificate, registered devices, and a matching profile.

1. Run xcodegen generate --spec project.yml and open
   StremioSkeleton.xcodeproj.
2. Assign the release team's Bunny bundle identifier and development team.
3. Keep machine-local export settings in the ignored
   config/ExportOptions.local.plist.
4. Select a generic iOS device and choose **Product > Archive**.
5. In Organizer, choose **Distribute App**, then the appropriate Development
   or Ad Hoc path.
6. Install the export and record its signing identity, version, build, launch,
   and legal playback results.

Apple documents this flow in
[Distributing your app to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
and
[Create an ad hoc provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile).

## 6. Upload to TestFlight or the App Store

Create the App Store Connect record before uploading. Archive a Release build
and use Organizer's **Distribute App** flow. TestFlight and App Store releases
normally use that archive instead of an IPA posted on GitHub.

Check Apple's current accepted Xcode and SDK versions immediately before the
release:
[Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).
Apple's broader workflow is in
[Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases/).

For the exact archive:

- confirm the App Store record, bundle ID, version, build, team, signing,
  entitlements, and icon
- generate Xcode's privacy report and compare it with PRIVACY.md, the bundled
  PrivacyInfo.xcprivacy, and App Store Connect answers
- supply a working review account or approved demo mode for account-only
  features
- explain add-ons and streaming-server behavior in review notes
- provide proof of rights for names, services, metadata, and streaming content
  if Apple asks
- test the processed build through TestFlight before App Review

Recheck Apple's
[required-reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
after dependency or code changes. The
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
are the final Apple reference for metadata, service access, streaming rights,
privacy, and trademark review.

## 7. Record the exact evidence

Keep separate records for:

- the source commit, dirty-tree review, and public-release scanner
- Rust and Swift test totals
- benchmark fixture checksum and methodology
- Bunny simulator install, launch, and deterministic playback
- device IPA checksum, architecture, bundle metadata, signature, and notices
- physical iPhone or iPad install and cold launch
- direct file, HLS, provider, subtitle, audio-track, seek, pause, resume,
  fallback, rotation, and Picture in Picture behavior
- TestFlight processing, App Review, and publication status

For Matroska playback, record the container, video and audio codecs, subtitle
type, visible frames, audio, seek result, track switching, stalls, and drops.
Apple decoder support varies by device and OS. A Rust benchmark does not prove
codec parity or physical-device playback.

Never publish an artifact only because an earlier build with the same version
passed. Record the SHA-256 checksum and source identity for every new artifact.
