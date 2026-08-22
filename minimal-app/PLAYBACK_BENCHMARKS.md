# Playback benchmark results

## Physical iPhone cadence regression

Measured 2026-08-22 on OrangeApple (iPhone 14 Pro Max) with the exact Debridio
stream `Obsession (2025) WEB-DL 1080p Ukr Eng [Hurtom].mkv` (6.80 GB,
23.98 fps). Each result below uses only uninterrupted `state=playing` samples.
The VLC pause/buffer event caused by manual timeline scrubbing is deliberately
outside its comparison window.

| Renderer | Continuous window | Mean / minimum fps | Added drops | Buffer | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| KSPlayer before fix | 81.4 s | 18.204 / 11.51 | 467 | 14.81–45.46 s | fail |
| VLC control, before scrub | 59.9 s | 23.981 / 21.53 | 0 | unavailable | pass |
| KSPlayer after fix | 84.6 s | 23.974 / 23.51 | 0 | 22.58–45.16 s | pass |

The failing KSPlayer run had no packet drops and retained at least 14.81 seconds
of decoded-forward buffer, ruling out download starvation for this regression.
Its modern `CADisplayLink` range preferred one callback per source frame even
though `videoClockSync` can hold until half a frame interval. The legacy path
already requested two callbacks per frame. Matching that cadence removed all
467 drops without switching player or decoder.

Paired Time Profiler captures also show that the cadence fix did not buy
smoothness with extra app CPU: the sampled CPU equivalent was 13.77% before and
13.15% after. The after-fix trace held source cadence for 67.46 seconds while
the device reported a Serious thermal state, with zero drops.

Raw device evidence is under `build/device-player-comparison/`:

- `performance-exact-before.log` and `.trace`
- `vlc-exact-control.log` and `.trace`
- `performance-exact-after.log` and `.trace`

## Simulator matrix

Measured on the iPhone 17 Pro simulator in strict single-player mode. The debug
overlay and logs require a visible decoded frame; audio-only state is not
counted as successful video playback. Parity means autoplay, visible frame,
seek, pause, resume, and duration all passed without silently switching to
another selectable player.

## Real network streams

| Selection | Real source | Rust route / decoder | Resolve | Visible playback | Steady cadence | Drops | Parity |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| Performance | Debridio/TorBox 1080p HEVC | bounded VLC, VideoToolbox-first | 0.98 s | 2.55 s | about 24 fps | 0 | pass |
| Performance | Debridio/TorBox 1080p H.264 MPEG-TS mislabeled as MP4 | KSPlayer FFmpeg, VideoToolbox requested | 4.32 s | 0.97 s | 23.1–24.6 / 24 fps | 0 | pass |
| VLC | same 1080p HEVC source | bounded VLC callback renderer | 3.56 s | 2.95 s | about 24 fps | 0 | pass |
| KSPlayer, synchronous | same 1080p HEVC source | FFmpeg, VideoToolbox requested | 0.82 s | 1.75 s | about 24 / 23.98 fps | 7 after forced seek | pass |
| KSPlayer, async A/B | same 1080p HEVC source | FFmpeg async, VideoToolbox requested | 0.78 s | 1.52 s | about 24 / 23.98 fps | 7 after forced seek | pass |
| AVPlayer | Apple BipBop adaptive HLS | AVFoundation system hardware path | n/a | 2.71 s | about 60 fps | 0 | pass |

The KSPlayer asynchronous experiment saved about 0.23 seconds but did not
reduce drops, so it remains off. Performance chooses the bounded VLC path for
HEVC because that renderer won the smoothness comparison, while retaining the
faster KSPlayer path for the relabeled transport stream.

One uncached provider link returned a 24,484-byte, 30-second “Downloading to
Provider” placeholder during all 40 readiness checks. The bridge rejected that
placeholder as still preparing instead of reporting false playback success.
No decoder can make that upstream file ready locally.

## Deterministic smoothness gate

| Fixture | Startup | Seek P95 | Seeks | Pause/resume | Stalls | Drops | Result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| native MP4 | 0.91 s | 260 ms | 5/5 | 5/5 | 0 | 0 | pass |
| native MPEG-TS HLS | 1.22 s | 160 ms | 5/5 | 5/5 | 0 | 0 | pass |
| AV1 + FLAC MKV | 0.55 s | 56 ms | 5/5 | 5/5 | 0 | 0 | pass |
| AAC audio-only | 0.65 s | 766 ms | 5/5 | 5/5 | 0 | 0 | pass |

The full report is generated at `build/player-smoothness-report.json` by
`scripts/benchmark-player-smoothness.sh`.

## Visual and device proof boundary

Simulator recordings were fully decoded and sampled across their timelines.
They show changing video frames, correct aspect-fit presentation, visible
controls, the debug overlay, and successful post-seek playback. The recordings
are under `build/player-debug-recordings/` and sampled contact sheets are under
`build/player-debug-contact-sheets/`.

Simulator results prove routing, stream compatibility, controls, and measured
frame delivery, but not final thermal behavior or hardware-decoder utilization
on a physical iPhone. The arm64 IPA is packaged separately for that last gate.
