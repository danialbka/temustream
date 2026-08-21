# Real playback verification

Date: 2026-08-20  
Device: iPhone 17 Pro Simulator, iOS 26.5  
Provider: Debridio - Scraper TB  
Player: KSPlayer `KSMEPlayer` (FFmpeg), revision `25c923b70d3d7881275e8f3d917e1e9752416e27`

Only cached Debridio entries marked with the lightning badge were counted as
playback passes. An uncached `Downloading to Provider` placeholder was not
counted as a playable link.

| Home movie | Tested cached source | Resolve | First visible frame | Result | Evidence |
| --- | --- | ---: | ---: | --- | --- |
| Obsession | HDRip x264, 402.31 MB | 381.1 ms | 9.761 s | Pass: visible Rlato frame | `build/real-playback/01-obsession.jpeg` |
| The Invite | WEBRip MP4, 808.04 MB | 200.6 ms | 13.116 s | Pass: visible Ferris-wheel frame | `build/real-playback/02-the-invite-portrait.jpeg` |
| Don't Say Good Luck | WEBRip MP4, 971.45 MB | 191.0 ms | 20.642 s | Pass: visible RANGE frame | `build/real-playback/03-dont-say-good-luck-cached.jpeg` |
| Masters of the Universe | 1080p x264, 5.07 GB | 415.8 ms | 8.243 s | Pass: visible MGM frame | `build/real-playback/05-masters-of-the-universe.jpeg` |
| Disclosure Day | 1080p H.264, 8.75 GB | 292.2 ms | 12.360 s | Pass: visible Universal frame | `build/real-playback/06-disclosure-day.jpeg` |

Resolve mean: **296.1 ms**. First-visible-frame mean: **12.824 s**; median:
**12.360 s**. The first-frame figure includes remote debrid/CDN transfer time.

The deterministic local E2E fixture isolates player startup from the provider:

| Path | Startup |
| --- | ---: |
| Direct MP4 | 572.5 ms |
| HLS | 109.4 ms |
| MKV with AV1 + FLAC | 110.4 ms |
| Torrent range stream | 125.2 ms |

## UI and aspect-ratio checks

- Stream cards extract quality and size into separate compact badges, including
  MB, GB, and TB values.
- The player explicitly uses aspect fit. The 16:9 fixture remains proportional
  in portrait and landscape without cropping, stretching, or unexpected bars.
- Close and rotate controls are part of the same visibility state as KSPlayer's
  transport and scrubber. They appear after the first frame and fade together.
- The rotate control requests either landscape direction so iOS can match the
  way the device is held. `07-fixture-landscape-controls.jpeg` shows the full
  landscape control state; `08-fixture-landscape-clean.jpeg` shows the clean
  playback state after automatic fade-out.
- PiP and background audio are enabled through the player options and the app's
  audio background mode. The app also starts KSPlayer's PiP controller while
  resigning active, before iOS suspends playback. Neither automatic nor manual
  sample-buffer PiP produced a floating window in iOS Simulator 26.5, so PiP
  remains a physical-device verification item.

## Simulator-specific negative coverage

- A real 8K HDR source exposed a KSPlayer 2.3.4 `UInt16` overflow. The project is
  pinned to the upstream revision containing the HDR metadata fix.
- iOS Simulator still cannot render the tested 8K and 4K AV1 hardware paths and
  its software fallback can hit a Simulator-only Metal assertion. Those cases
  now show an explicit unsupported-on-Simulator message instead of a black
  screen or crash. The physical-device path remains enabled.
- A lower-resolution AV1 + FLAC MKV passes the deterministic KSPlayer E2E test,
  separating the Simulator resolution limit from basic codec/container support.
