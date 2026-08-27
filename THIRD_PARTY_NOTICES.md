# Third-party notices

The root [MIT License](LICENSE) covers original project code only. It does not
replace the licenses of dependencies, services, add-ons, media, or the separate
upstream Stremio application.

The versions below are the direct dependencies pinned by the current build
configuration. Transitive dependency versions are recorded in Swift Package
Manager's `Package.resolved` file and the Watch Together backend's
`package-lock.json`.

| Component | Pinned version | License | Notes |
| --- | --- | --- | --- |
| KSPlayer | local fork of revision `25c923b` | GPL-3.0 | The complete license is at `minimal-app/Vendor/KSPlayer/LICENSE`. Local changes must remain available with corresponding source when distributed under the GPL. |
| kingslay/FFmpegKit | 6.1.4 | GPL-3.0 | Linked by the Bunny player. The fetched source contains its GPL-3.0 license. FFmpeg configuration and optional codec libraries can add further obligations. |
| MobileVLCKit | 3.7.3 | LGPL-2.1-only for VLCKit | Downloaded from VideoLAN by `minimal-app/scripts/fetch-vlc.sh` with a pinned SHA-256. The bundled VLC modules and codec libraries may carry additional compatible licenses and notices. |
| Convex Swift | 0.8.1 | Apache-2.0 | Used by the optional iOS Watch Together feature. |
| LiveKit Swift | 2.16.0 | Apache-2.0 | Used by the optional iOS Watch Together feature. Its NOTICE file must be preserved where required. |
| LiveKit WebRTC XCFramework | 144.7559.11 | MIT | Transitive LiveKit media dependency. |
| LiveKit UniFFI XCFramework | 0.0.6 | Apache-2.0 | Transitive LiveKit dependency. |
| Swift Protobuf | 1.38.1 | Apache-2.0 | Transitive LiveKit dependency. Bundled protobuf and abseil notices also apply. |
| Convex JavaScript | 1.45.0 | Apache-2.0 | Optional development backend dependency. |
| LiveKit Server SDK for Node.js | 2.18.0 | Apache-2.0 | Optional development backend dependency. |

## Distribution checklist

Before publishing an IPA, app archive, or simulator bundle:

1. Re-resolve the dependency graph and compare it with this file.
2. Preserve every required copyright notice, license text, and NOTICE file.
3. Provide the corresponding source and local modifications required by GPL or
   LGPL components, including reproducible build instructions where required.
4. Confirm that the way the app links and distributes GPL-3.0 components is
   compatible with the intended distribution channel and Apple's terms.
5. Review the exact FFmpeg and VLC build configurations for optional codecs and
   their licenses.
6. Do not assume an App Store upload, TestFlight build, or ad hoc IPA is covered
   merely because the repository's original code is MIT.

This inventory is an engineering aid, not legal advice. Have the final binary
and distribution plan reviewed by someone qualified to advise on open-source
and trademark obligations.
