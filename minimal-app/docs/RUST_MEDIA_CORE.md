# Bunny Rust media core

TemuStremio's direct Matroska and WebM path is implemented in
`rust/StremioPlaybackCore/src/media/`. It has no Cargo dependencies. The Rust
code parses container structure and returns compressed packets through a small
C ABI. `iOS/App/BunnyNativeDecoder.swift` supplies random-access bytes and
passes those packets to Apple sample-buffer renderers.

This split matters: the project owns the container parser, track selection,
seeking, and subtitle processing. Apple still owns codec decompression and
presentation.

## Audio output design

Bunny keeps compressed audio on Apple's documented custom-player path:
`AVSampleBufferAudioRenderer` and `AVSampleBufferRenderSynchronizer`. Replacing
that pair with a separate PCM engine would make the app responsible for a
second playback clock, A/V drift correction, seeking, route changes, and
AirPlay synchronization without improving codec ownership.

Rust parses the packet framing Apple needs but does not alter the sound. It
currently derives AC-3 and E-AC-3 speaker layouts and E-AC-3's variable
256/512/768/1,536-frame duration from each sync frame. Core Media then receives
the compressed packet with its native channel layout and exact presentation
time.

The iOS layer uses the movie-playback category and long-form-video route,
advertises multichannel capability, and permits mono, stereo, and multichannel
Spatial Audio. The output-channel preference is bounded to what the active
route reports: AirPods normally expose two hardware channels and let iOS apply
the user's Spatial Audio setting, while a capable HDMI route can expose more.
There is no app EQ, bass boost, compressor, or loudness normalization in this
path.

## Playback flow

1. Bunny first gives HLS, MP4, MOV, and M4V to AVFoundation.
2. Direct Matroska or WebM opens through a bounded HTTP byte-range reader or a
   local file reader.
3. Rust indexes metadata, tracks, cues, and clusters.
4. Rust returns one selected compressed packet at a time.
5. Swift builds Core Media format descriptions and sample buffers.
6. AVSampleBufferDisplayLayer and AVSampleBufferAudioRenderer decode and
   present the selected video and audio.
7. If Apple cannot decode the source, the app can try a configured streaming
   server's HLS compatibility URL.

## Implemented support

| Area | Implemented |
| --- | --- |
| Containers | Matroska and WebM EBML header, segment information, tracks, cues, known or unknown-size clusters, `SimpleBlock`, and `BlockGroup` |
| Lacing | none, Xiph, EBML, and fixed-size |
| Timing | timestamp scale, per-track timestamp scale, codec delay, block duration, discard padding, signed presentation timestamps, default duration |
| Seeking | cue-based seeking, cue relative positions, cluster fallback, and first selected packet retrieval |
| Tracks | video, audio, and subtitle discovery; default and forced flags; audio and subtitle selection |
| Video IDs | H.264, HEVC, AV1, VP9, and MPEG-4 Part 2 |
| Audio IDs | AAC, AC-3, E-AC-3, FLAC, Opus, PCM, TrueHD, and DTS |
| Text subtitles | SubRip/SRT, WebVTT, ASS, and SSA parsing or packet normalization |
| Bitmap subtitles | PGS palettes, windows, fragmented objects, RLE, composition, cropping, clipping, forced flags, and clear events |
| Safety limits | metadata size, block size, subtitle document and cue size, PGS document size, object pixels, cached objects, composition objects, presentations, and output RGBA bytes |

Recognizing a codec ID does not guarantee direct playback. The Swift bridge
currently builds Apple format descriptions for H.264, HEVC, AV1, VP9, MPEG-4,
AAC, AC-3, E-AC-3, FLAC, Opus, and PCM. Availability still depends on the
target OS, hardware, codec profile, and valid codec-private data. TrueHD and DTS
are identified so the app can choose compatibility playback, but the direct
Apple sample-buffer path does not claim to decode them.

## Verification completed on 2026-08-28

- 51 Rust unit tests passed, including all four valid E-AC-3 block counts.
- The Swift package passed 149 XCTest cases and 7 Swift Testing cases. One
  additional live Wikimedia test remained skipped because live network
  coverage is opt-in.
- A Release iOS Simulator app built and launched with the Rust XCFramework.
- A 60-second 1280 by 720 Matroska fixture with H.264 video, AAC audio, and
  embedded SubRip subtitles played visibly for more than 24 seconds.
- The observed mixed-media run held about 29.8 frames per second with zero
  reported dropped frames, zero stalls, and about 1.2 seconds of buffered media.
- Audio was accepted by the Apple renderer and the embedded subtitle was
  visible.
- A deterministic H.264/E-AC-3 5.1 fixture used six independent source tones.
  Bunny identified `L C R Ls Rs LFE`, recovered from an automatic audio-route
  flush, completed 5 of 5 seeks and 5 of 5 pause/resume cycles, reported zero
  stalls or dropped video frames, and measured 1.00001 times real-time.
- A separate H.264/AAC stereo fixture exercised the stereo Spatial Audio
  permission and time-domain pitch path with the same interaction gates. It
  reported zero stalls or dropped video frames and 1.00001 times real-time.
- An AV1 and FLAC Matroska fixture passed Rust indexing, demux, and seek tests.
  The tested Simulator did not produce a visible AV1 frame, so that run is not
  counted as AV1 playback proof.

The Simulator route reported two channels and no Spatial Audio capability. It
therefore proves configuration, decoding, timing, and recovery, but not AirPods
sound quality. A physical-device AirPods listening check remains a separate
release gate, along with device codec and thermal behavior.

## Reproducible benchmark

Run:

```sh
./scripts/benchmark-rust-media-core.sh
```

The default run stream-copies the tracked one-second fixture into a 300-second
Matroska file when FFmpeg is installed. It records the fixture checksum,
configuration, every sample, and summary statistics in the ignored file
`build/benchmarks/rust-media-core.json`.

The recorded arm64 macOS release run used this exact fixture:

| Field | Value |
| --- | ---: |
| SHA-256 | `f6dcb9f20172a26c767463713e881a684caf041acf7adfc73d13e02e4436df75` |
| Size | 3,630,354 bytes |
| Duration | 300 seconds |
| Tracks | AV1 video and FLAC audio |
| Cues and clusters | 300 each |
| Compressed packets | 7,800 |

| Rust operation | Median |
| --- | ---: |
| Open and index metadata | 44.709 microseconds |
| Demux all 7,800 packets | 1.910 milliseconds |
| Payload throughput | 1,780.13 MiB/s |
| Cue seek plus first packet | 405 nanoseconds per operation |

The same run measured `ffprobe` as an external-process reference: 25.876
milliseconds for metadata and 35.843 milliseconds for packet counting.
Those values include process startup, file I/O, and a different scope of work.
They do not establish a general speed win over FFmpeg, KSPlayer, VLC, or any
decoder. The useful claim is narrower: on this fixture and machine, the Rust
container path is fast enough to keep parser overhead far below media playback
time.

## Current limits

- ContentEncodings, header stripping, encrypted blocks, BlockAdditions, and
  CodecState are not interpreted.
- Linked or multi-segment Matroska files are not joined automatically.
- A cue that has CueBlockNumber but no CueRelativePosition starts from its
  cluster.
- Later timestamps inside a laced block use DefaultDuration when present or an
  even share of BlockDuration. Matroska does not always provide enough data to
  reconstruct every laced timestamp exactly.
- ASS and SSA text is normalized, but typography, animation, karaoke, and
  positioning commands are not rendered.
- PGS output does not infer an end time when the stream omits a clear event.
- The Rust module is not an MP4, MOV, MPEG-TS, HLS, DASH, AVI, or torrent
  implementation. Existing Apple or configured server paths handle those
  sources.
- DRM-protected media and DRM bypass are outside the project.

When adding format support, add malformed-input tests, explicit allocation
limits, a same-fixture benchmark, and visible playback evidence. Do not describe
packet parsing as codec playback proof.
