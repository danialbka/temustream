# UI state screenshot matrix

| Screenshot | State covered |
| --- | --- |
| `catalog-loading.png` | Initial network loading |
| `home-cinemeta.png` | Loaded Cinemeta catalog and source dropdown |
| `home-letterboxd.png` | Loaded Letterboxd Recommendations selection |
| `home-series.png` | TV Series selected with the horizontal Continue Watching poster row and dot-matrix progress |
| `home-card-layout.png` | Wide, tall, and standard poster sources crop-fill identical cards while one- and two-line titles retain aligned metadata |
| `search-idle.png` | Dedicated search route before a query, including recent-search presentation |
| `search-results.png` | Cross-provider movie search results and profile-scoped query state |
| `profiles-picker.png` | Multiple local profiles, active profile, editing, and profile creation |
| `home-light-custom-theme.png` | Light catalog using a persisted custom purple accent and adaptive surfaces |
| `catalog-error.png` | Catalog network or protocol failure |
| `details-streams.png` | Metadata, trailer action, and direct/torrent stream choices |
| `details-resume.png` | Persisted resume with dot-matrix progress and trailer actions below Add to Library |
| `details-series-episodes.png` | Series trailer action, full-width episode routes, season picker, dot-matrix resume and episode progress, and completed tick |
| `details-cast-movie.png` | Movie summary metadata, credits, and horizontally scrollable provider-backed trivia cards |
| `details-cast-series.png` | Series summary metadata, credits, episode inventory, and horizontally scrollable provider-backed trivia cards |
| `episode-streams.png` | Dedicated episode route with thumbnail, summary, dot-matrix resume progress, provider filters, and streams |
| `episode-up-next.png` | Compact next-episode thumbnail, episode number, countdown, and immediate playback action |
| `library-empty.png` | Empty saved library |
| `library-synced.png` | Account-synchronized saved title |
| `addons-offline.png` | Add-on management and offline torrent server |
| `settings-subtitles.png` | Persisted subtitle size, color, weight, background, shadow, and live preview |
| `settings-appearance-light.png` | System/Light/Dark controls, accent presets, custom colour picker, and live theme preview |
| `account-signed-out.png` | Sign-in form |
| `account-signed-in.png` | Synced account summary |
| `torrent-starting.png` | Torrent resolution progress |
| `playback-unavailable.png` | Player resolution error |
| `stream-failover-countdown.png` | Three-second automatic next-stream countdown and immediate continue action |
| `player-active.png` | Default Bunny playback surface |

The workflow uses local fixtures and a clean install for each capture, so account, network,
catalog, poster, and playback states are reproducible without live-service drift.

`library-synced.png` and `account-signed-in.png` use deterministic production-style snapshot
views because the ad-hoc signed harness has no Keychain access-group entitlement.
The normal app's account and library behavior remains covered by the account-sync E2E workflow.
