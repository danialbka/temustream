# Releasing TemuStremio

This guide separates a public source release, a local sideloading IPA, an ad
hoc export for registered devices, and an App Store or TestFlight upload. They
are not interchangeable.

## Release blockers to settle first

The checked-in bundle identifiers begin with `local.` and are development
placeholders. Replace them in `minimal-app/project.yml` with unique identifiers
owned by the release team, then regenerate the Xcode project. Do not add a
developer team, certificate, provisioning profile, authentication key, or
exported signing file to Git.

The name **TemuStremio** contains third-party product names. Apple's review
rules prohibit using another developer's product name or protected material in
an app name without approval. Obtain the necessary permission or choose a name
you can document the rights to before an App Store submission. The unofficial
notice in the README helps users understand the project, but it is not a grant
of trademark rights.

Binary distribution also needs a license review. KSPlayer and the selected
FFmpegKit package are GPL-3.0, while MobileVLCKit and its bundled components
have their own terms. Work through [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)
for the exact build before publishing an IPA.

The current tree no longer contains the personal device label that appeared in
older benchmark and OTA-script revisions, and the history audit found no
credential or Apple device identifier. The old label is still reachable in Git
history. Before making this existing repository public, either approve a
carefully reviewed history rewrite with a backup, or publish a new repository
from a clean `git archive`. Do not rewrite or force-push history as an ordinary
release-script step.

## 1. Freeze and inspect the source

From the repository root:

```sh
git status --short
./scripts/public-release-check.sh --history
./minimal-app/scripts/test.sh
SKELETON_PUBLIC_RELEASE=1 ./minimal-app/scripts/verify.sh
```

Review every tracked, staged, unstaged, and untracked file. The release gate
hides matched credential values, but it cannot tell whether ordinary text is
private. Read documentation, fixtures, screenshots, and benchmark notes for
names, device labels, account details, private URLs, and copyrighted test media.

Keep source tests tracked. Ignore only generated results, coverage, logs,
screenshots, archives, provisioning material, and machine-local configuration.

Before tagging:

- update the marketing version and monotonically increasing build number for
  each target in `minimal-app/project.yml`
- regenerate with `xcodegen generate --spec project.yml`
- confirm the generated project matches the spec
- validate the iOS, tvOS, and standalone watchOS schemes separately
- check that Watch Together endpoints are empty unless the production backend
  has completed its security, privacy, retention, and abuse-readiness work
- review `Package.resolved`, `package-lock.json`, licenses, and notices
- archive the exact commit, not a dirty working tree

## 2. Make a public source release

Use a signed or annotated tag and let GitHub create source archives from tracked
files. If building a source archive locally, use `git archive` so ignored local
files cannot slip into it:

```sh
version='vX.Y.Z'
git archive --format=tar.gz --prefix="TemuStremio-${version}/" \
  -o "TemuStremio-${version}.tar.gz" "$version"
shasum -a 256 "TemuStremio-${version}.tar.gz" \
  > "TemuStremio-${version}.tar.gz.sha256"
```

Attach the checksum and release notes. Do not attach a local `.env`, signing
configuration, Xcode archive, app container, Sideloadly snapshot, private log,
or credentials. Enable GitHub private vulnerability reporting, secret
scanning, dependency alerts, and branch protection before announcing the repo.

## 3. Build a local sideloading handoff IPA

`minimal-app/scripts/build-device.sh` compiles an arm64 device app without Apple
signing, applies an ad hoc code signature, and packages the expected `Payload/`
layout:

```sh
cd minimal-app
SKELETON_PUBLIC_RELEASE=1 \
  STREMIO_SOURCE_ID="$(git rev-parse HEAD)" \
  ./scripts/build-device.sh
unzip -tq build/StremioSkeleton-device.ipa
shasum -a 256 build/StremioSkeleton-device.ipa
```

Public-release mode performs a clean app-target build and forces both optional
Watch Together endpoint values to empty, even if this Mac has an ignored local
configuration file. Omit that mode only for a deliberate internal build whose
backend has completed the security and privacy review below.

For an iCloud or File Provider checkout, run the same build from a verified
local scratch workspace:

```sh
SKELETON_PUBLIC_RELEASE=1 ./scripts/dev-workflow.sh build-device
```

With the default scratch location, the resulting IPA and provenance JSON are
under `/private/tmp/stremio-dev-workflow/workspace/build/`. The workflow hashes
every overlaid source file and records its materialized source identity in
`/private/tmp/stremio-dev-workflow/latest.json`.

The resulting IPA is a local handoff for a sideloading tool. It is not an App
Store build, not an ad hoc distribution export, and not installable until it is
signed with an appropriate identity and provisioning profile. Keep the signed
result private. Registered-device profiles expose team and device information.

## 4. Export for registered devices

Apple's ad hoc flow requires an explicit App ID, an Apple Distribution
certificate, registered devices, and an ad hoc provisioning profile. Automatic
signing can manage the profile, or it can be created in the developer account.

1. Generate and open the project:

   ```sh
   cd minimal-app
   xcodegen generate --spec project.yml
   open StremioSkeleton.xcodeproj
   ```

2. Set the release team's unique bundle identifiers and team in Xcode. Keep
   machine-local export settings in `config/ExportOptions.local.plist`, which is
   ignored.
3. Select a generic device destination, choose **Product > Archive**, and wait
   for Organizer.
4. Choose **Distribute App**, then **Ad Hoc** or **Development** as appropriate.
5. Install only on registered devices and verify the installed version, build,
   signing identity, launch, and legal test playback.

Apple's current registered-device documentation is
[Distributing your app to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices),
and its profile steps are in
[Create an ad hoc provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile).

## 5. Upload to TestFlight or the App Store

Create the app record in App Store Connect before uploading. Archive a Release
build, then use Organizer's **Distribute App** flow to upload it. TestFlight and
App Store distribution normally use the uploaded archive; they do not require
posting an IPA on GitHub.

Apple changes its accepted Xcode and SDK versions. Check
[Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
immediately before the release rather than relying on a version copied into
this guide. Apple's broader flow is documented in
[Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases/).

For every platform build:

- confirm the app record, bundle ID, version, build, signing, entitlements, and
  icon belong to the intended target
- generate Xcode's privacy report and compare it with `PRIVACY.md`, the bundled
  `PrivacyInfo.xcprivacy`, and App Store Connect answers
- supply a working review account or an approved demo mode for account-only
  features
- explain add-ons, streaming-server behavior, and optional Watch Together in
  review notes
- provide documentation showing the right to use third-party names, services,
  streaming content, and metadata when requested
- test the exact archive through TestFlight before submitting it for review

Apple requires required-reason API declarations in the privacy manifest. The
current app declares its app-local UserDefaults use and elapsed-time measurement
with system uptime. Recheck this after dependency or code changes against
[Apple's required-reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
are the final reference for metadata, third-party services, streaming rights,
privacy, and copycat or trademark review.

## 6. Verify the exact release artifact

A release is not complete when compilation succeeds. Record separate evidence
for:

- source tests and the clean-tree security scan
- simulator launch and deterministic E2E checks
- Apple TV launch, remote focus, playback, and stream failover
- standalone Apple Watch install, on-watch navigation, and direct HTTPS/HLS
  playback without an iPhone app
- physical iPhone or iPad install, cold launch, account persistence, direct
  file playback, HLS, provider streams, subtitles, audio tracks, seeking,
  rotation, Picture in Picture, and fallback behavior
- the uploaded build's processing, TestFlight availability, App Review state,
  and final publication state

Keep a SHA-256 checksum and the Git commit identity with each local artifact.
Never publish an artifact merely because an earlier build with the same version
passed.
