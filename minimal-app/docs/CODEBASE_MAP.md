# TemuStremio codebase map

Use this map from `minimal-app/`. The application is layered so protocol and
persistence rules can be tested without iOS, while UIKit/SwiftUI, decoder, and
service integrations stay at the edges.

## Runtime path

```text
StremioSkeletonApp
  -> AppModel + RootView
  -> HomeView / DetailsView / EpisodeStreamsView
  -> ResolvingPlayerScreen
  -> AppModel.playbackPlan
     -> direct URL, TorrentStreamingClient, or TorBoxPlaybackResolver
     -> optional StreamTransportBridge / compatibility URL
  -> PlayerScreen
     -> Bunny
        -> AVFoundation for Apple-native sources
        -> BunnyNativeDecoder + Rust Matroska/WebM core for direct containers
```

The Apple TV target keeps the protocol and app-state layers but replaces the
touch UI and custom player stack:

```text
TemuStreamTVApp
  -> AppModel + TVRootView
  -> TVHomeView / TVSearchView / TVDetailsView / TVEpisodeStreamsView
  -> TVResolvingPlayerView
  -> AVPlayerViewController
```

The standalone Apple Watch target uses a smaller native path and includes only
the shared protocol files it needs:

```text
TemuStremioWatchApp
  -> WatchAppModel + WatchRootView
  -> catalog / search / library / details / stream selection
  -> StremioAccountClient / TorrentStreamingClient / WatchStreamCompatibility
  -> AVPlayer + SwiftUI VideoPlayer
  -> TemuStremioWatchContainer (nonlaunchable App Store archive wrapper)
```

`ResolvingPlayerScreen` owns source failover, resume state, and next-episode
autoplay. `PlayerScreen` owns the Bunny handoff and shared overlays. Bunny
selects either Apple's native asset path or the Rust direct-container path.

## Ownership by area

| Area | Start here | Responsibilities |
| --- | --- | --- |
| App entry and test routes | `iOS/App/StremioSkeletonApp.swift` | App composition plus Simulator-only fixture/stress entry points |
| App state | `iOS/App/AppModel.swift` | Catalog/search/details/streams, library/account state, progress, and playback-plan orchestration |
| Main SwiftUI | `iOS/App/Views.swift` | Tabs, home grid, continue watching, details, episode streams, library, add-ons, settings, account |
| Apple TV SwiftUI | `tvOS/App/` | Sidebar navigation, focus shelves/cards, cinematic details, episode and stream selection, profiles, settings, and native AVKit playback |
| Apple Watch SwiftUI | `watchOS/App/` | Standalone catalogs, search, secure Stremio sign-in, account-isolated library/progress and add-on sync, configurable streaming-server conversion, Digital Crown seeking, and native AVKit playback |
| Apple Watch compatibility | `Sources/StremioSkeletonCore/WatchStreamCompatibility.swift` | Allows native HTTPS HLS/video plus HLS from the exact configured server origin; unsupported sources receive an actionable reason instead of being forced through AVPlayer |
| Apple Watch distribution | `project.yml`, `watchOS/Container/Info.plist` | Single executable watchOS app target plus the nonlaunchable `application.watchapp2-container` root stub Apple requires to package a watch-only App Store archive |
| Theme | `iOS/App/AppTheme.swift`, `Sources/StremioSkeletonCore/AppearancePreferences.swift` | Light/dark and accent preferences |
| Protocol/API | `Sources/StremioSkeletonCore/Models.swift`, `Sources/StremioSkeletonCore/AddonEndpoint.swift`, `Sources/StremioSkeletonCore/AddonClient.swift` | Stremio payloads, safe resource URLs, and HTTP decoding |
| Catalog paging | `Sources/StremioSkeletonCore/CatalogPaging.swift` | Deduplication, skip progression, and terminal-page policy |
| Local/account data | `Sources/StremioSkeletonCore/LibraryStore.swift`, `Sources/StremioSkeletonCore/PlaybackProgressStore.swift`, `Sources/StremioSkeletonCore/PlaybackCompletionStore.swift`, `Sources/StremioSkeletonCore/StremioAccountClient.swift`, `iOS/App/SessionStore.swift` | Persistence, resume/completion state, Stremio account sync, and session storage |
| Episode policy | `Sources/StremioSkeletonCore/EpisodeResumeSelection.swift` | Default/persisted season, series/season resume, and next-episode timing |
| Shared player flow | `iOS/App/PlayerView.swift` | Resolving/failover, autoplay card, resume handoff, Bunny presentation, and shared chrome |
| Bunny player | `iOS/App/BunnyPlayerView.swift` | Bunny playback model, renderer, controls, tracks, timeline, subtitles, and diagnostics |
| Bunny direct decoder | `iOS/App/BunnyNativeDecoder.swift` | Bounded file/HTTP range reads, Rust ABI bridge, Core Media descriptions, sample-buffer rendering, seeking, and track selection |
| Rust media core | `rust/StremioPlaybackCore/src/media/`, `rust/StremioPlaybackCore/include/StremioPlaybackCore.h` | Matroska/WebM EBML, tracks, cues, lacing, compressed packets, text subtitles, bounded PGS, and C ABI |
| Playback policy core | `rust/StremioPlaybackCore/src/lib.rs`, `iOS/App/PlaybackPerformanceCore.swift` | Player routing, clock, MPEG-TS timing, and Swift bridge |
| Audio session | `iOS/App/PlaybackAudioSession.swift` | Playback/voice audio-session transitions and microphone permission |
| Provider transport | `iOS/App/TorBoxPlaybackResolver.swift`, `iOS/App/StreamTransportBridge.swift`, `Sources/StremioSkeletonCore/TorrentStreamingClient.swift` | Short-lived provider URL resolution, mislabeled TS normalization, range serving/cache, and streaming-server API |
| Diagnostics | `iOS/App/PlayerDiagnostics.swift` | Simulator stress/probe screens and structured playback reports |
| Watch Together iOS | `iOS/App/WatchTogetherModel.swift`, `iOS/App/WatchTogetherViews.swift` | Convex subscriptions, LiveKit room/data/audio transport, profiles/friends/rooms, and UI controls |
| Watch sync policy | `Sources/StremioSkeletonCore/WatchPlaybackSync.swift`, `Sources/StremioSkeletonCore/WatchTogetherPreferences.swift` | Version ordering, drift adjustments, voice state, and feature default/persistence |
| Watch Together backend | `Backend/watch-together/convex/schema.ts`, `Backend/watch-together/convex/profiles.ts`, `Backend/watch-together/convex/friends.ts`, `Backend/watch-together/convex/rooms.ts`, `Backend/watch-together/convex/livekit.ts`, `Backend/watch-together/convex/auth.ts` | Durable profiles/friends/rooms/playback plus short-lived LiveKit join tokens |

## Tests and fixtures

- `Tests/StremioSkeletonCoreTests/` mirrors the platform-light core. Add a
  focused test beside the owning source change.
- `Fixtures/` contains deterministic manifest/catalog/meta/stream/subtitle and
  UI-state inputs. Keep secrets and provider credentials out of fixtures.
- `iOS/App/UIStateScreenshots.swift` is the focused screenshot app;
  `UIStateBunnyPlayerStub.swift` and `UIStateWatchTogetherStub.swift` replace
  heavy runtime surfaces only for that harness.
- `scripts/e2e-simulator.sh` runs the production app against a local range
  server and synthetic media. `scripts/ui-state-screenshots.sh` captures named,
  deterministic UI states described in `UI_STATE_MATRIX.md`.
- `scripts/benchmark-rust-media-core.sh` measures same-fixture open, demux, and
  seek work. `scripts/benchmark-player-smoothness.sh` is a playback gate.
  `scripts/benchmark-obsession-20.sh` is a provider-stream gate and is not
  interchangeable with fixtures or physical-device playback.
- Playback expectations and evidence boundaries live in
  `PLAYBACK_BENCHMARKS.md` and `REAL_PLAYBACK_BENCHMARK.md`.

## Build and configuration ownership

| Path | Role |
| --- | --- |
| `Package.swift` | Swift package and core/test targets |
| `project.yml` | Canonical iOS target, dependencies, signing defaults, bundle metadata, and schemes |
| `StremioSkeleton.xcodeproj/` | XcodeGen output; regenerate, do not hand-edit |
| `scripts/build-support.sh` | Shared Xcode/Rust build lock helpers |
| `scripts/build-cache-retention.sh` | Marker ownership, active leases, shared-cache retention, and report-only legacy inventory |
| `scripts/build-rust-core.sh` | Rust device/simulator libraries and XCFramework packaging |
| `scripts/benchmark-rust-media-core.sh` | Reproducible Matroska open/demux/seek benchmark and JSON report |
| `scripts/build-simulator.sh` | Release Simulator app and ZIP |
| `scripts/build-tvos.sh` | tvOS Swift SDK type-check plus Release Apple TV Simulator app and ZIP when the tvOS runtime is installed |
| `scripts/build-watchos.sh` | watchOS Swift SDK type-check plus Release Apple Watch Simulator app and ZIP when the watchOS runtime is installed |
| `scripts/build-device.sh` | Ad-hoc-signed device app, ZIP, sideloadable IPA, and provenance |
| `config/WatchTogether.xcconfig` | Checked-in public build-setting indirection |
| `scripts/configure-watch-together.sh` | Writes ignored local Convex/LiveKit endpoint config |
| `Backend/watch-together/package.json` | Convex backend commands and pinned npm workflow |

`build/`, `.build/`, dependency XCFrameworks, Rust `target/`, backend
`node_modules/`, local endpoint config, `.env.local`, Sideloadly snapshots, and
install receipts are generated or machine-local. Numbered Finder copies of a
plist, entitlement, Xcode project, or artifact are never canonical. Use
`scripts/repo-health.sh --report` to inventory them; do not remove them during a
feature task.

## Canonical commands

| Goal | Command | What it proves |
| --- | --- | --- |
| Read-only hygiene inventory | `./scripts/repo-health.sh --report` | Reports clutter, hotspots, and sensitive-path risks without mutating files |
| Complete cloud-safe hygiene content scan | `./scripts/dev-workflow.sh prepare && ./scripts/repo-health.sh --content-root /private/tmp/stremio-dev-workflow/workspace` | Uses the verified local source mirror instead of hydrating cloud placeholders |
| Enforce hygiene policy | `./scripts/repo-health.sh --check` | Same scan with warning/error exit status |
| Materialize current dirty source safely | `./scripts/dev-workflow.sh prepare` | Hash-verified local workspace outside File Provider |
| Inspect generated cache storage | `./scripts/dev-workflow.sh cache-report` | Owned-cache keep/prune decisions plus unmarked legacy candidates; no deletion |
| Prune owned excess caches | `./scripts/dev-workflow.sh prune-cache` | Applies bounded retention only to valid project marker-owned caches |
| Unit tests in that workspace | `./scripts/dev-workflow.sh test` | Rust and Swift unit suites |
| Simulator build | `./scripts/dev-workflow.sh build-simulator` | Release Simulator archive with source identity |
| tvOS source gate | `./scripts/dev-workflow.sh typecheck-tvos` | Swift 6 type-check of the complete TV target; does not require a Simulator runtime |
| watchOS source gate | `./scripts/dev-workflow.sh typecheck-watchos` | Swift 6 type-check of the standalone Watch target; does not require a Simulator runtime |
| Apple TV Simulator build | `./scripts/dev-workflow.sh build-tvos` | Release tvOS Simulator archive; requires the tvOS runtime from Xcode Components |
| Apple Watch Simulator build | `./scripts/dev-workflow.sh build-watchos` | Release watchOS Simulator archive; requires the watchOS runtime from Xcode Components |
| One or more UI states | `./scripts/dev-workflow.sh screenshots home-series details-series-episodes` | Named Simulator UI runtime and PNG artifacts |
| Device artifact | `./scripts/dev-workflow.sh build-device` | Device IPA and source provenance; not an install |
| Direct unit loop | `./scripts/test.sh` | Rust and Swift unit suites in the source checkout |
| Deterministic app E2E | `./scripts/e2e-simulator.sh` | Fixture catalog/account/playback startup in Simulator |
| Full local gate | `./scripts/verify.sh` | Tests, builds, benchmarks, E2E, and UI-state screenshots |
| OTA preflight | `./scripts/fast-ota.sh doctor` | Device tunnel and cached signing readiness only |
| Authorized OTA | `./scripts/fast-ota.sh update` | Build/sign/install, installed-build verification, launch, and AutoRefresh staging |
| Full Sideloadly renewal fallback | `./scripts/sideloadly-cli.sh update` | Profile-renewal path plus verified install/launch |

The materialized workflow is the preferred recovery when the cloud-backed
checkout causes Xcode, `rsync`, or file coordination to pause. Its metadata is
written outside the repository; do not replace it with an unchecked manual copy.

## Search recipes

```sh
# Find a visible screen or accessibility hook.
rg -n 'struct .*View|accessibilityIdentifier' iOS/App/Views.swift iOS/App/WatchTogetherViews.swift

# Trace resume, completion, and autoplay end to end.
rg -n 'resume|recordPlaybackProgress|PlaybackCompletion|EpisodeAutoplay' iOS/App Sources Tests

# Trace stream preparation and failover.
rg -n 'playbackPlan|TorBoxPlaybackResolver|StreamTransportBridge|compatibility|failover' iOS/App Sources Tests

# Trace the Bunny native and Rust paths without loading all player code.
rg -n 'Bunny|customRust|bunnyRust' iOS/App/PlayerView.swift iOS/App/BunnyPlayerView.swift iOS/App/BunnyNativeDecoder.swift rust/StremioPlaybackCore/src

# Find harness switches and their consumers.
rg -n 'SKELETON_[A-Z0-9_]+' iOS/App scripts

# List first-party source while avoiding generated dependency trees.
rg --files Sources Tests iOS/App tvOS/App watchOS/App Backend/watch-together/convex rust/StremioPlaybackCore/src scripts docs
```

## Handoff checklist

State exactly which level was observed: source/static checks, package state,
Simulator build, Simulator runtime, device artifact, installed device build,
and real-stream behavior. For player comparisons, use the same URL and duration
and report visible frames, startup, seeking, pause/resume, stalls, frame drops,
and buffering independently.
