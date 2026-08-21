# UI state screenshot matrix

| Screenshot | State covered |
| --- | --- |
| `catalog-loading.png` | Initial network loading |
| `home-cinemeta.png` | Loaded Cinemeta catalog and source dropdown |
| `home-letterboxd.png` | Loaded Letterboxd Recommendations selection |
| `catalog-error.png` | Catalog network or protocol failure |
| `details-streams.png` | Metadata plus direct and torrent stream choices |
| `library-empty.png` | Empty saved library |
| `library-synced.png` | Account-synchronized saved title |
| `addons-offline.png` | Add-on management and offline torrent server |
| `account-signed-out.png` | Sign-in form |
| `account-signed-in.png` | Synced account summary |
| `torrent-starting.png` | Torrent resolution progress |
| `playback-unavailable.png` | Player resolution error |
| `player-active.png` | Native AVPlayer playback surface |

The workflow uses local fixtures and a clean install for each capture, so account, network,
catalog, poster, and playback states are reproducible without live-service drift.

`library-synced.png` and `account-signed-in.png` use deterministic production-style snapshot
views because the ad-hoc signed harness has no Keychain access-group entitlement.
The normal app's account and library behavior remains covered by the account-sync E2E workflow.
