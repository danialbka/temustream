# Bunny for Apple Watch

The watchOS app is a standalone Bunny client. It does not need an iPhone
session and does not use WatchConnectivity. Catalogs, search, Stremio account
sign-in, library and installed add-on sync, playback progress, stream
selection, streaming-server resolution, and playback all run on the watch.
Watch Together is intentionally excluded.

## What plays on Apple Watch

The watch player uses the watchOS-native `AVPlayer` and `VideoPlayer` path. It
accepts:

- HTTPS HLS playlists, normally ending in `.m3u8`
- HTTPS MP4, M4V, and MOV files that AVPlayer can decode
- Other HTTPS responses when the server returns an AVPlayer-compatible media
  type

The stream picker explains why it cannot open a source instead of forcing it
through AVPlayer. Without a configured streaming server, torrent and magnet
sources, external-app links, DASH manifests, MKV, WebM, AVI, FLV, WMV, and
streams marked as needing a compatibility player remain unavailable.

You can opt in to a streaming server from Settings on the watch. Bunny
accepts an HTTPS endpoint, or HTTP only for localhost/private-network hosts. It
rejects public HTTP, embedded credentials, query tokens, and fragments in the
server URL. For torrent sources, the watch asks that server to resolve the
selected file and then requests an H.264/HEVC plus AAC/MP3 HLS conversion. For
an incompatible direct HTTP(S) source, it requests the same HLS conversion.
The returned playlist is accepted only when it comes from the exact configured
server origin. The server must be one you operate or are authorized to use.

This does not make every stream playable. The server must be online and support
the Stremio streaming-server heartbeat, torrent create, settings, and `hlsv2`
routes. DRM-protected media, external-app-only links, sources without a direct
URL or valid info hash, and server conversion failures remain unsupported.

Resolved and converted stream URLs are kept in memory for playback. Playback
history stores title, episode, provider, a credential-stripped catalog origin,
and time position. It never persists the resolved media URL, its query string,
or the streaming-server conversion URL.

## Account and local data

Create, edit, switch, archive, and restore local viewing profiles from the home
screen or Settings. Each profile owns a separate library, progress and
completion history, add-on collection, search history, ratings,
recommendations, playback preferences, configured streaming server, and
account session. Existing single-profile watch data is copied into the first
profile without deleting the legacy files.

Sign in from Settings > Stremio Account using the watch keyboard or dictation.
The password is used only for the login request and is not saved. On a physical
watch, each profile's returned Stremio session is stored in Keychain with
`AfterFirstUnlockThisDeviceOnly` accessibility. Simulator sessions and synced
add-on URLs use protected Application Support files because Simulator Keychain
state is unsuitable for this development workflow. On a physical watch,
synced add-on URLs are stored in Keychain as well.

Stremio accounts have one canonical library rather than server-side viewing
profiles. To prevent a guest profile from replacing that canonical snapshot,
only the first local profile pulls and pushes the account library. Secondary
profiles keep their library local, while their signed-in add-on collection can
still synchronize. Add-on installs and removals first pull the current remote
collection, then push the updated full snapshot so add-ons outside the watch's
bounded UI are not silently deleted. Playback progress remains local to this
watch because the account API used here does not synchronize playback position.

## Watch-native controls

The player presents a compact video surface with large 15-second back,
play/pause, and 30-second forward buttons. Tap the timeline gauge and turn the
Digital Crown to seek in five-second steps. The speed control cycles through
0.75x, 1x, 1.25x, and 1.5x. Embedded audio and caption tracks have a native
watch picker. Previous and next episode buttons use provider episode order;
the next episode starts at the true end only when per-profile autoplay is on.
Playback checkpoints are saved every 15 seconds and at exit. Validated provider
intro markers produce a large Skip Intro button. Triple-tap the video to enter
an immersive edge-to-edge view with all player chrome hidden. Triple-tap the
expanded video again to return to the controls.

If source preparation fails, the resolver tries the remaining sources in
provider order. A decoder or network failure in AVPlayer exposes Retry Stream
and Try Next Source controls. A source is remembered only after AVPlayer
reaches ready state. The preference contains hashed provider/stream metadata,
never a URL, query token, resolved CDN address, or torrent credential. TorBox
permalinks are resolved immediately before playback; the short-lived result
stays in memory and an incompatible resolved container still requires the
configured HLS server.

The rest of the app uses watchOS lists, short rows, native search input, and
small-screen navigation. It does not reuse the iPhone player chrome or include
VLC, FFmpeg, KSPlayer, LiveKit, Convex, WatchConnectivity, or Watch Together.
TorBox permalinks are resolved just in time with Foundation; token-bearing
results remain memory-only. Server-assisted sources still play through watchOS
AVPlayer after conversion to HLS.

## Feature and platform-limit matrix

| Product area | watchOS status | Notes |
| --- | --- | --- |
| Catalog home | Implemented | Loads installed add-on catalogs in bounded, watch-sized sections. |
| Browse all and paging | Implemented | Browse All uses protocol `skip` paging when the add-on declares it and deduplicates pages. |
| Search | Implemented | Provider search plus private local matching for titles, actors, directors, writers, and genres; Movie/Series filter and per-profile recent searches included. |
| Details | Implemented | Description, release, rating, runtime, certification, country, language, status, genres, director, writers, cast, awards, and related titles. |
| Trailers | Implemented with format boundary | Direct HLS/native HTTPS trailers play in-app. HTTPS webpage trailers open as external links because a YouTube page is not an AVPlayer media stream. |
| Trivia | Implemented | Provider facts preserve spoiler labels; exact IMDb-to-Wikidata Wikipedia production facts include revision and CC BY-SA attribution. |
| Series and episodes | Implemented | Season selection persists per profile; rows show thumbnail, progress, completion, and a series resume action. |
| Viewing profiles | Implemented | Local create/edit/select/archive/restore with isolated state and recoverable data directories. |
| Stremio sign-in | Implemented | Email/password login, per-profile secure session, explicit sync, and sign-out. Passwords are never stored. |
| Account library | Implemented for primary profile | Stremio has one remote library. Secondary local profiles deliberately cannot overwrite it and keep their library local. |
| Installed add-on sync | Implemented | Pull-before-push preserves remote add-ons beyond the watch display limit. |
| Library and progress | Implemented | Per-profile My Library, continue watching, 15-second checkpoints, completion state, and removal. Resolved URLs are never stored. |
| Ratings and For You | Implemented | Per-profile dislike/like/love signals, local explainable ranking, visible-only impression recording, and reset controls. |
| Catalog source ranking | Implemented | A proven source is promoted using only hashed, stable metadata after AVPlayer reaches ready state. |
| Stream ordering | Implemented | Current and Big files modes share the iPhone ranking policy; cached sources stay at the top in both modes and no provider result is hidden. |
| Direct playback | Implemented | Native AVPlayer path for compatible HTTPS HLS and direct/negotiated HTTPS video. |
| Audio and captions | Implemented for embedded tracks | AVPlayer audible/legible selection, per-profile language preference, captions off/on, and system caption rendering. |
| External subtitle files | Platform-native limit | watchOS AVPlayer does not attach a loose Stremio WebVTT/SRT URL as a selectable track. It must already be embedded/muxed or included by an authorized HLS server. Custom subtitle renderers are intentionally not bundled. |
| Intro skip | Implemented | Shown only for validated, stream-scoped provider intro metadata; no guessed skip ranges. |
| Previous/next/autoplay | Implemented | Manual controls plus true-end autoplay; specials stay isolated from regular seasons. |
| Retry and fallback | Implemented | Resolution tries candidates in sequence; player exposes retry and next-source recovery without persisting candidate URLs. |
| Torrent and incompatible containers | Configurable | Requires an authorized user-configured streaming server that resolves/transcodes to trusted-origin HLS. No server is bundled. |
| TorBox permalinks | Implemented | Foundation-only just-in-time resolution. First-party code keeps CDN/token URLs session-only and does not persist or log their components. Apple AVPlayer/CoreMedia diagnostics can expose the full asset URL, so use short-lived URLs and do not share system logs. |
| Playback speed and preferences | Implemented | Per-profile autoplay, rate, audio/caption languages, captions enabled, and a restrained accent preset. |
| Watch Together, friends, voice chat | Excluded by product scope | No WatchConnectivity, LiveKit, Convex, microphone access, room state, or phone dependency is linked into the target. |
| VLC, FFmpeg, KSPlayer, Bunny decoders | Platform/product limit | Those desktop/mobile compatibility stacks are not watchOS products. The watch uses AVPlayer or an authorized HLS server and reports unsupported codecs/containers. |
| PGS, ASS, VobSub custom rendering | Platform/product limit | Depends on the excluded custom decoder/rendering stacks. Embedded AVPlayer captions remain available. |
| PiP, orientation lock, pinch-to-fill, brightness gestures | Not applicable on watchOS | These phone/TV presentation controls have no useful watch analogue; the Digital Crown and large tap targets replace them. |
| DRM bypass and external-app-only streams | Unsupported | Bunny does not bypass DRM or another service's access rules, and the standalone watch player cannot delegate playback to an iPhone app. |

## Deterministic simulator playback capture

Debug builds have an opt-in launch route that opens an injected HTTPS HLS URL
through the real `WatchPlaybackSessionView`. Release builds compile this hook
out. The URL is read from the process environment, never written to defaults,
logs, progress, source, or the project file. Use a lawful public test stream or
a stream you control:

```sh
WATCH_DEMO_HLS_URL='https://example.test/demo/master.m3u8'
xcrun simctl install booted /absolute/path/to/TemuStremioWatch.app
SIMCTL_CHILD_TEMUSTREMIO_WATCH_DEMO=1 \
SIMCTL_CHILD_TEMUSTREMIO_WATCH_DEMO_STREAM_URL="$WATCH_DEMO_HLS_URL" \
SIMCTL_CHILD_TEMUSTREMIO_WATCH_DEMO_TITLE='Bunny Watch Playback' \
xcrun simctl launch --terminate-running-process booted local.stremio.skeleton.watch.watchkitapp
```

The hook rejects non-HTTPS URLs, embedded credentials, and non-HLS paths. A
normal launch without both opt-in values always opens the regular home screen.

## Build and verify

The watch target requires XcodeGen 2.42 or newer, Xcode with the watchOS SDK,
and watchOS 10 or newer.

The generated project deliberately has two production targets:

- `TemuStremioWatch` is the single executable watchOS app. It contains all
  Swift code and resources, has `WKWatchOnly = YES`, and is skipped as a
  top-level install product because the archive wrapper owns distribution.
- `TemuStremioWatchContainer` is Apple's nonlaunchable iOS root stub
  (`application.watchapp2-container`). It has no source code or companion
  experience; its only job is to embed the watch app and package a watch-only
  App Store archive.

This matches Apple's current
[watch-only project structure](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps/):
the watch code uses a modern single watchOS app target, while the root stub sets
the distribution bundle identifier and packages the app for App Store upload.

Use `TemuStremioWatch` to run on a watch or watch simulator. Use
`TemuStremioWatchDistribution` only for Archive. The two-scheme split is
intentional: it keeps the watch app runnable while making the archive product
the required root container.

Run the source gate even when the watchOS Simulator runtime is not installed:

```sh
./scripts/dev-workflow.sh typecheck-watchos
```

Install the watchOS Simulator runtime in Xcode Settings under Components, then
build the simulator app and ZIP:

```sh
./scripts/dev-workflow.sh build-watchos
```

For interactive testing, regenerate the project, open it, choose the
`TemuStremioWatch` scheme, and select an Apple Watch destination:

```sh
xcodegen generate --spec project.yml
open StremioSkeleton.xcodeproj
```

Before a device or store archive, set a unique public bundle identifier and a
valid development team in `project.yml`. The root identifier and nested watch
identifier must remain related, for example `com.example.bunny.watch`
and `com.example.bunny.watch.watchkitapp`. Then select the
`TemuStremioWatchDistribution` scheme, choose a generic iOS device destination,
and use Product > Archive. Organizer can validate and export/upload the
resulting watch-only archive; the root stub never installs an app on iPhone.

Xcode must have the matching watchOS platform component installed even for an
iOS-rooted watch-only archive. Install it from Xcode > Settings > Components
before treating the distribution archive as verified. The checked-in
`TemuStremioWatchAppIcon` is assigned to the watch target; inspect its compiled
appearance on every supported watch size before submission. Signing values are
intentionally not hard-coded in the source.

## Add stream providers

Cinemeta is installed as the default metadata catalog. To add a stream
provider, open Settings on the watch, enter its complete HTTPS `manifest.json`
URL, and tap Install Add-on. Signed-in installs and removals synchronize with
the account. Private configured add-on URLs are kept in protected local storage
and must never be placed in source files, fixtures, screenshots, or bug reports.

You can also open an individual HTTPS media URL from the home screen. This path
is useful for testing a provider's HLS output without installing its manifest.
