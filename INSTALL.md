# Install Stremio iOS Enhancer V7

> **Legacy enhancer only:** this guide modifies an old official Stremio IPA.
> It does not build, sign, or install the Bunny app in `minimal-app/`, and none
> of its KSPlayer or VLCKit notes apply to the Bunny release target.

This guide installs the enhancer into Stremio's official unsigned IPA on your
own Mac. No Stremio application binary, Apple credential, signing certificate,
or provisioning profile is distributed by this project.

## Compatibility

- Stremio iOS `2.0.3` build `18`
- Bundle identifier before sideload signing: `com.stremio.pal`
- iPhone or iPad running iOS/iPadOS 13 or newer
- arm64 devices
- Sideloadly on macOS

Other Stremio releases may change private player classes or KSPlayer entry
points. Do not inject V7 into an unverified version.

## 1. Download the official Stremio IPA

Download `stremio_iOS.ipa` directly from Stremio's official CDN:

<https://dl.strem.io/apple/2.0.3b18/ios/stremio_iOS.ipa>

Verify the upstream file in Terminal:

```sh
echo 'f23c50e52756d90573c3328d7f5bb2bc5930b1fe478bf7318013d83a80cfd37a  stremio_iOS.ipa' \
  | shasum -a 256 -c -
```

The expected result is `stremio_iOS.ipa: OK`. Stop if it does not match.

## 2. Download and verify the enhancer

From this project's latest GitHub release, download both:

- `StremioPlayerEnhancer.dylib`
- `StremioPlayerEnhancer.dylib.sha256`

Keep both files in the same folder, open Terminal in that folder, and run:

```sh
shasum -a 256 -c StremioPlayerEnhancer.dylib.sha256
```

The expected result is `StremioPlayerEnhancer.dylib: OK`.

## 3. Install with Sideloadly

1. Connect the iPhone or iPad to the Mac, unlock it, and trust the Mac.
2. Open the verified official IPA in Sideloadly and select the device.
3. Open **Advanced Options**, enable **Tweak Injection**, and add
   `StremioPlayerEnhancer.dylib`.
4. Leave Cydia Substrate, Substitute, Sideload Spoofer, and unrelated tweaks
   disabled.
5. Sign and install with your own Apple account. The enhancer and application
   are re-signed locally by Sideloadly; this release contains no Apple signing
   material.
6. For an update or refresh, reuse the same Apple account and generated bundle
   identity. Do not delete the installed app first if retaining its local data
   matters.

With a free Apple account, provisioning normally expires after seven days.
Enable Sideloadly's automatic refresh after USB pairing and Wi-Fi sync are set
up.

## Using the controls

- Tap **Rotate video** to force portrait or landscape even while the iPhone's
  Rotation Lock is enabled.
- Tap the **Picture in Picture** button to enter native system PiP.
- While a video is playing, return to the Home Screen to start PiP
  automatically.
- Keep **Use VLCKit** and the deprecated AVPlayer backend disabled for native
  PiP. V7 selects Stremio's bundled KSPlayer backend on first configuration.

Use only lawful media and user-selected add-ons. This unofficial project is not
affiliated with or endorsed by Stremio.
