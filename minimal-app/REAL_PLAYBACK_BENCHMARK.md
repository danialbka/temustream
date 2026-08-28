# Real provider playback gate

The current Rust-player branch has a fresh Simulator regression pass using a
locally retained 64 MiB capture of the provider stream that previously failed.
The H.264/AAC MPEG-TS bytes reached first frame in 687.6 ms, played for more
than 110 seconds at about 24 fps with zero reported dropped frames or stalls,
and sought from startup to 89.8 seconds in 1,031.6 ms.

This is exact provider-byte regression evidence, not a fresh live account run.
There is still no physical-device playback pass for this Rust-player build.

Historical KSPlayer and VLC results are preserved on
`archive/full-player-stack-2026-08-27`. They must not be copied forward as
proof for Bunny's Rust path.

For the next provider run, record only redacted metadata:

- source class and media codecs, without the provider URL or token
- resolution, duration, and container
- resolve time and first visible frame
- audio result
- seek, pause, resume, and track-switch result
- stalls, dropped frames, and buffered duration
- whether direct Rust playback or configured HLS compatibility was used
- Simulator versus physical device

Do not store the resolved CDN URL, query string, account token, add-on
credential, device identifier, or private provider response in Git.
