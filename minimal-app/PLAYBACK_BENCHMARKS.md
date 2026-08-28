# Bunny Rust playback benchmarks

Date: 2026-08-28

This file records results for the `no-license` branch. The older KSPlayer,
FFmpegKit, and MobileVLCKit comparison belongs to
`archive/full-player-stack-2026-08-27` and is not evidence for the current
binary.

## Container-core benchmark

The release benchmark used a generated 300-second AV1 and FLAC Matroska fixture
with SHA-256
`c2a6d345d306dc68429eda5ac4266f4d5d10281347851c2b551dc17f7d06ca50`.
It contained 300 cues, 300 clusters, and 7,800 compressed packets.

| Operation | Median |
| --- | ---: |
| Open and index | 37.250 microseconds |
| Demux every packet | 1.626 milliseconds |
| Payload throughput | 2,090.62 MiB/s |
| Cue seek plus first packet | 339 nanoseconds |

The benchmark ran 5 warmups and 25 recorded repetitions, with 500 deterministic
seek operations per repetition. Run it with:

```sh
./scripts/benchmark-rust-media-core.sh
```

The JSON report is written to the ignored
`build/benchmarks/rust-media-core.json`.

The same run recorded `ffprobe` process time as 23.415 milliseconds for
metadata and 27.738 milliseconds for packet counting. This is not a direct
performance comparison. It includes process startup and file I/O, and each
implementation performs different work.

## Visible Simulator playback

The verified mixed fixture was 60.021 seconds, 1280 by 720, with H.264 video,
AAC audio, and an embedded SubRip subtitle track. The Rust path opened the
Matroska file, fed both media tracks to Apple renderers, and displayed the
subtitle.

| Observation | Result |
| --- | ---: |
| Ready | 894.1 ms |
| Observed playback position | more than 24 seconds |
| Video cadence | about 29.8 fps |
| Reported dropped frames | 0 |
| Reported stalls | 0 |
| Buffered media | about 1.2 seconds |
| Audio | accepted and rendered |
| Subtitle | visible |

An AV1 and FLAC fixture passed Rust parser, demux, and seek coverage, but the
tested iOS Simulator did not display an AV1 frame. It is recorded as parser
coverage, not visible playback support.

## Network regression playback

The captured provider regression fixture contains 64 MiB of MPEG transport
stream bytes with H.264 video and AAC audio. Bunny exposed those same bytes as
a first-party byte-range HLS playlist without transcoding or downloading the
whole source first.

| Observation | Result |
| --- | ---: |
| Ready | 687.6 ms |
| Continuous observation | more than 110 seconds |
| Video cadence | about 24 fps |
| Reported dropped frames | 0 |
| Reported stalls | 0 |
| Seek | requested 90.0 s, landed at 89.8 s |
| Seeked ready time | 1,031.6 ms |

A separate 731 MiB public remote Matroska file opened in 8,302.8 ms through
the Rust core and VideoToolbox, then ran for two minutes with no source-read
failure, recovery loop, dropped frame, or recorded stall. The network reader
reused its validated HTTP session and fetched bounded 2 MiB ranges; the Rust
core indexed later Matroska clusters only when playback or seeking needed them.

## Audio route verification

The custom audio path follows Apple's sample-buffer player architecture rather
than running an independent PCM clock. Rust supplies packet timing and Dolby
layout metadata; iOS handles codec decompression, route-aware output, and the
user's Spatial Audio preference.

| Fixture | Startup | Seeks | Pause/resume | Stalls | Dropped frames | Real-time ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| E-AC-3 5.1, 48 kHz | 998.6 ms | 5/5 | 5/5 | 0 | 0 | 1.00001 |
| AAC stereo, 48 kHz | 722.2 ms | 5/5 | 5/5 | 0 | 0 | 1.00001 |

The 5.1 run identified `L C R Ls Rs LFE` and recovered from the same automatic
renderer-flush notification used to model a Bluetooth route change. The
Simulator had no Spatial Audio route, so these numbers are not an AirPods sound
quality result.

## What remains before release

- repeat direct H.264/AAC Matroska, HLS, seeking, track switching, subtitles,
  pause/resume, rotation, PiP, and compatibility fallback on a physical iPhone
- test HEVC, AV1, VP9, AC-3, E-AC-3, FLAC, Opus, and PCM on supported hardware
- rerun a real provider source without storing or printing its resolved URL
- inspect the exact IPA for removed player frameworks and linked libraries

A parser microbenchmark is not a codec benchmark. A Simulator frame is not a
physical-device pass. Keep those evidence levels separate.
