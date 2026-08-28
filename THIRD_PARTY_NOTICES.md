# Third-party notices

The root [MIT License](LICENSE) covers original project code. It does not
replace licenses or terms for tools, platform SDKs, hosted services, add-ons,
metadata, codecs, or media.

## Stremio credit

Bunny is an independent client that works with Stremio accounts and add-ons.
Thank you to the Stremio maintainers and contributors for building and sharing
that ecosystem.

No Stremio source code is copied into the Bunny iOS target. Stremio projects
keep their own licenses. For reference, the official
[stremio-core](https://github.com/Stremio/stremio-core/blob/development/LICENSE.md)
project is published under the MIT License, while
[stremio-web](https://github.com/Stremio/stremio-web) is published under
GPL-2.0. Those licenses govern those projects and do not replace this
repository's MIT License.

Bunny is not affiliated with or endorsed by Stremio. The Stremio name is used
only to explain account and add-on compatibility.

## Current iOS app

The Bunny Matroska, WebM, subtitle, and PGS implementation in
`minimal-app/rust/StremioPlaybackCore/` is original project code. Its Cargo
manifest has no third-party packages. Both iOS targets also have no Swift
package dependencies.

The Rust static library uses the Rust standard library. This repository pins
Rust 1.95.0 in `minimal-app/rust-toolchain.toml` and includes the matching
library notice at:

`minimal-app/ThirdParty/Rust/1.95.0/COPYRIGHT-library.html`

SHA-256:
`90567e2718bf7fd65a71a3a43c5596488e80e5f51ed02bfea6fec54458b5f3d1`

The build bundles that exact notice and the root MIT license. Rust standard
library code is available under MIT or Apache-2.0 terms and includes notices
for code incorporated into the library. Recheck the bundled file whenever the
pinned toolchain changes.

The iOS target does not include or link KSPlayer, FFmpegKit, FFmpeg,
MobileVLCKit, Convex, LiveKit, WebRTC, or SwiftProtobuf. AVFoundation, Core
Media, VideoToolbox, and the other Apple frameworks come from the platform SDK
and are governed by Apple's developer agreements.

## Optional backend source

`minimal-app/Backend/watch-together/` remains in the repository as optional
development source. It is excluded from the current iOS target and is not part
of the Bunny IPA.

Its direct JavaScript dependencies are pinned in
`minimal-app/Backend/watch-together/package-lock.json`:

| Component | Pinned version | License |
| --- | --- | --- |
| Convex JavaScript | 1.45.0 | Apache-2.0 |
| LiveKit Server SDK for Node.js | 2.18.0 | Apache-2.0 |

The lockfile includes more development and transitive packages. Audit their
exact license metadata before distributing a prepared backend bundle or a
`node_modules` tree. This repository does not distribute `node_modules`.

## Check every release

For each IPA, archive, source tag, or backend package:

1. Record `rustc --version` and confirm the bundled Rust notice matches it.
2. Inspect the app's linked libraries and `Frameworks/` directory.
3. Confirm removed media and Watch Together binaries are absent.
4. Include every license and notice required by the exact artifact.
5. Review codec patents, media rights, service terms, Apple policy, and
   trademarks as separate questions.

This file is an engineering inventory, not legal advice. Review the exact
binary for the intended distribution channel.
