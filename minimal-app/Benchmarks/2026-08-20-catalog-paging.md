# Catalog source and paging benchmark — 2026-08-20

## Result

The app now uses a `Set`-backed page accumulator keyed by media type and ID.
In a release build with 10 pages / 1,000 unique items:

| Operation | Median |
| --- | ---: |
| Decode a 100-item first page | 0.188 ms |
| Append and deduplicate 1,000 items | 0.201 ms |
| Naive repeated-array scan for 1,000 items | 21.238 ms |

The paging accumulator was **105.8x faster** than the naive scan. It also stops
after an empty page or a provider that repeats the same page, preventing an
infinite request loop.

## Live provider timings

Seven sequential HTTP samples were taken from Singapore on 2026-08-20. These
measure remote response time and are informational rather than CI gates.

| Provider route | Items | Median |
| --- | ---: | ---: |
| Cinemeta first page | 50 | 224 ms |
| Cinemeta `skip=50` | 50 | 188 ms |
| Stremboxd Popular This Week first page | 100 | 293 ms |
| Stremboxd `skip=100` | 100 | 282 ms |

The client advances `skip` by the response count instead of assuming a fixed
page size. This matches both live providers and is covered by unit and simulator
E2E tests.
