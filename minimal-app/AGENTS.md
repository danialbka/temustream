# TemuStream app working guide

## Scope

This file applies to `minimal-app/`, the SwiftUI iOS, tvOS, and watchOS applications. The sibling
`enhancer/` tree at the Git root is a separate legacy runtime-extension project;
do not change it for app work unless the task names it.

Start in this directory and preserve the existing working tree:

```sh
git status --short --untracked-files=all
./scripts/repo-health.sh --report
```

- Treat every pre-existing modification and untracked file as user work.
- Do not clean, reset, delete, rename, stage, commit, push, install, or deploy
  unless the current request authorizes that action.
- Never use numbered Finder copies such as `Info 2.plist` or
  `StremioSkeleton 3.xcodeproj` as canonical inputs. Report them with
  `repo-health.sh`; removal needs separate confirmation.
- Read `docs/CODEBASE_MAP.md` before broad changes. It maps ownership and the
  shortest search path for UI, playback, backend, and test work.

## Source ownership

- Put protocol models, endpoint construction, persistence, preference policy,
  and other platform-light logic in `Sources/StremioSkeletonCore/`. Add its
  tests under `Tests/StremioSkeletonCoreTests/`.
- Put app lifecycle and feature orchestration in `iOS/App/AppModel.swift`; keep
  SwiftUI navigation and catalog/detail/settings surfaces in
  `iOS/App/Views.swift`.
- Keep Apple TV lifecycle, focus-driven navigation, shelves, details, settings,
  and AVKit playback in `tvOS/App/`. Share `AppModel` and the platform-light
  core, but do not pull the iOS custom-player stack into the tvOS target.
- Put cross-player routing, stream failover, resume, autoplay, and shared player
  chrome in `iOS/App/PlayerView.swift`. Bunny-specific UI/state belongs in
  `iOS/App/BunnyPlayerView.swift`; its Swift range/sample-buffer bridge belongs
  in `iOS/App/BunnyNativeDecoder.swift`. Matroska/WebM, subtitle, PGS, and ABI
  code belongs in `rust/StremioPlaybackCore/src/media/`.
- Keep provider URL normalization in `iOS/App/TorBoxPlaybackResolver.swift`,
  byte-range delivery in `iOS/App/StreamTransportBridge.swift`, and generic
  streaming-server contracts in
  `Sources/StremioSkeletonCore/TorrentStreamingClient.swift`.
- Keep Watch Together iOS state and LiveKit transport in
  `iOS/App/WatchTogetherModel.swift`, its SwiftUI in
  `iOS/App/WatchTogetherViews.swift`, durable sync rules in
  `Sources/StremioSkeletonCore/WatchPlaybackSync.swift`, and Convex functions in
  `Backend/watch-together/convex/`.
- `project.yml` is the Xcode project source of truth. Build scripts run
  `xcodegen`; never hand-edit `StremioSkeleton.xcodeproj/project.pbxproj`.

## Generated and local-only state

Do not hand-edit or use generated output as source:

- `build/`, `.build/`, `.swiftpm/`, `rust/**/target/`,
  `Backend/watch-together/build/`, and `Backend/watch-together/node_modules/`
- `build/dependencies/StremioPlaybackCore.xcframework`
- `Backend/watch-together/convex/_generated/` (regenerate with Convex tooling)
- `StremioSkeleton.xcodeproj/` (regenerate from `project.yml`)
- `config/WatchTogether.local.xcconfig`, `Backend/watch-together/.env.local`,
  local Sideloadly snapshots, provisioning material, and device receipts

Never print, commit, or copy credentials into fixtures or docs. Public
Watch Together endpoints are configured with
`scripts/configure-watch-together.sh`; LiveKit secrets remain backend-only.

All routine SwiftPM, Rust, Xcode DerivedData, Simulator product, and screenshot
compiler caches share `${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}`.
Do not create task-named paths such as `/private/tmp/stremio-fix-derived` or
unique SwiftPM scratch directories. Use `scripts/dev-workflow.sh`, or pass a
deliberate `STREMIO_BUILD_CACHE_ROOT` when isolation is actually required.
Build entry points register marker-owned caches, protect them with live PID
leases, keep the two newest roots of each kind, and prune only owned excess.
Unmarked legacy directories are report-only. Inspect the policy with:

```sh
./scripts/dev-workflow.sh cache-report
```

Read `docs/BUILD_CACHE_RETENTION.md` before changing cache paths or cleanup
behavior. Never bypass its ownership marker to delete a broad temporary path.

## Fast navigation

Use `rg` before opening the large Swift files:

```sh
rg -n 'struct (HomeView|DetailsView|EpisodeStreamsView|SettingsView)' iOS/App/Views.swift
rg -n 'struct (PlayerScreen|ResolvingPlayerScreen)|handlePlayerFailure' iOS/App/PlayerView.swift
rg -n 'func (playbackPlan|recordPlaybackProgress|streamProviders)' iOS/App/AppModel.swift
rg -n 'WatchTogether|WatchRoom|voiceState' iOS/App Sources/StremioSkeletonCore Backend/watch-together/convex
rg -n 'func test.*(Resume|Playback|Watch|Subtitle)' Tests/StremioSkeletonCoreTests
rg -n 'SKELETON_[A-Z0-9_]+' iOS/App scripts
rg --files Sources Tests iOS/App Backend/watch-together/convex rust/StremioPlaybackCore scripts docs
```

## Development loop

Use the smallest relevant check first. The source tree may be cloud-backed; if
Xcode or file copying pauses, use the materialized workflow rather than making
ad-hoc copies:

```sh
./scripts/dev-workflow.sh test
./scripts/dev-workflow.sh build-simulator
./scripts/dev-workflow.sh typecheck-tvos
./scripts/dev-workflow.sh build-tvos
./scripts/dev-workflow.sh screenshots home-series
./scripts/dev-workflow.sh build-device
./scripts/dev-workflow.sh cache-report
```

The workflow overlays current tracked and allowed untracked edits into a
hash-verified workspace under `/private/tmp` and writes provenance metadata. A
direct local loop remains available:

```sh
./scripts/test.sh
swift test --filter PlaybackProgressStoreTests
./scripts/build-simulator.sh
UI_SCREENSHOT_STATES='home-series details-series-episodes' ./scripts/ui-state-screenshots.sh
./scripts/e2e-simulator.sh
```

Run `./scripts/verify.sh` only when the full local gate is warranted; it includes
unit tests, both builds, benchmarks, Simulator E2E, and the UI-state matrix.

## Proof gates

Report these separately; passing one does not imply the next:

1. Static/unit: Rust and Swift tests pass.
2. Artifact: Release Simulator or device build completes and its archive is
   valid.
3. Simulator runtime: the named E2E/UI state launches and its expected result is
   observed. A screenshot or crash dialog alone is not a pass.
4. Playback: use the same stream when comparing players and report startup,
   visible frames, seek, pause/resume, stalls, drops, and buffering separately.
   Deterministic fixtures and provider streams are distinct evidence.
5. Device: only an explicitly authorized OTA/install counts. Run
   `./scripts/fast-ota.sh doctor` before `./scripts/fast-ota.sh update`, then
   require installed bundle/build verification and launch evidence. An IPA or an
   enabled Sideloadly Start button is not installation proof.

Do not broaden a requested UI or playback fix into backend, signing, or cleanup
work. If an adjacent change is required, explain the dependency before making
it.
