# Asset provenance

The rabbit artwork, app icons, Apple TV icon layers, and six animal profile
images were created on 2026-08-27 with OpenAI's built-in image generation
tool. The Bunny banner title was updated on 2026-08-28. The final assets were
checked at original resolution and selected to avoid third-party logos,
celebrity likenesses, and copyrighted characters.

Generated-image output can still resemble existing work by accident. Review
the final files again before a store submission or merchandising use. The app
name itself also needs a separate trademark review.

## Output inventory

| Asset | Dimensions | SHA-256 |
| --- | ---: | --- |
| `docs/assets/bunny-banner.png` | 1774 x 887 | `36d77b65128d6b36f420e3a46469f30dab985161393d4021778d7baf6bdc709a` |
| `docs/assets/bunny-app-icon-master.png` | 1254 x 1254 | `e5ccb6db7afe3dd4534b21fbe9ab1812e209188e1c714a44b78f39be590a8a36` |
| iOS App Store icon | 1024 x 1024 | `80bf997be11e5fa92b5be843d70d380618bfd930647774e884a815796452bfe4` |
| watchOS App Store icon | 1024 x 1024 | `80bf997be11e5fa92b5be843d70d380618bfd930647774e884a815796452bfe4` |
| tvOS App Store foreground layer | 1280 x 768 | `7236100440b8950138951c447af8acdc3e664572cd912df4d11d00e02065307c` |
| tvOS App Store background layer | 1280 x 768 | `60b7e59ff0a144b00fddbf7a44af1d68f4796c93b49d81f11f055e02e323a3b8` |
| tvOS Home Screen foreground layer | 400 x 240 | `cd118b279db258f8ecfe41b632a827e33262016da6e4a44062de25368d5276cc` |
| tvOS Home Screen background layer | 400 x 240 | `5c85de4e37bd99333ef2b54f7d6f89fa93af3eaefdc68b1521abf6d219566df2` |
| `ProfileRedPanda.imageset/profile-red-panda.png` | 512 x 512 | `0fea2eebfc3bda8a6df03f5cf8b45b8f1198e4d3fb66d6581f5aba597d45184d` |
| `ProfileArcticFox.imageset/profile-arctic-fox.png` | 512 x 512 | `dfa0db9019372dc9003841779107e348fe34acf2893b87d91585180c0adebfc7` |
| `ProfileGoldenPuppyOriginal.imageset/profile-golden-puppy-original.png` | 512 x 512 | `980c14e2be46b0479acbdeedb76695222ff748992d4863474594aab0bd778e78` |
| `ProfileLopBunnyOriginal.imageset/profile-lop-bunny-original.png` | 512 x 512 | `64b6630379967639526a8adc79e6472312e152294d4fbf0813e4af1e969dbb94` |
| `ProfileSeaOtterOriginal.imageset/profile-sea-otter-original.png` | 512 x 512 | `59404abe8d2fb927c460c780fb8ec33468b357fbc36b10083276e4f1eea85ca6` |
| `ProfileTabbyKittenOriginal.imageset/profile-tabby-kitten-original.png` | 512 x 512 | `910a51641d5803c341d57d067e012fe4b5177578a74312f0e6bf107359f6306f` |

Profile paths in the table are relative to
`minimal-app/iOS/Resources/Assets.xcassets/`. The iOS and watchOS catalog icons
reuse the same generated master.

## Banner prompt

The final banner used the approved rabbit artwork as an edit target:

```text
Use case: text-localization
Asset type: GitHub repository README banner
Primary request: replace the existing title with the exact word "Bunny"
Text: "Bunny"
Constraints: keep the wide composition, normal orange-brown lop-eared rabbit, dark navy background, colored light ribbons, particles, lighting, and white geometric type; change only the displayed name
Avoid: any other text, logos, symbols, extra animals, altered rabbit anatomy, upright ears, watermark, border, or rounded-corner mask
```

The generated source ID is
`exec-857e45d5-ba06-49cf-be94-59eed85f68de`. The final image is 1774 x 887
and was checked at its original resolution.

## App icon prompt

```text
Using the original Bunny banner as the mascot reference, create a new square app-icon master.
Use case: app-icon
Canvas: exact 1:1 square, 1024 by 1024 appearance
Subject: the same normal friendly orange-brown lop-eared rabbit, centered head-and-upper-body portrait, natural anatomy, two drooping ears, plain rabbit face
Background: deep midnight navy with restrained violet and electric-blue flowing light ribbons
Style: polished tactile realistic 3D illustration, clean silhouette, readable at 20px, premium iOS app icon
Lighting: warm orange key light with subtle cool rim light
Constraints: no text, no letters, no play icon, no symbol or marking on the rabbit, no Apple logo, no Stremio logo, no third-party marks, no watermark, no transparency, no rounded corners baked into the image
Avoid: costume, triangle shapes on the face, duplicate animals, clutter, tiny details, border, mockup frame
```

The generated master was downsampled into the asset-catalog variants without
adding a mask or rounded corners.

## Apple TV icon layers

tvOS requires a rectangular layered icon. The background layer was generated
from the approved rabbit master with this prompt:

```text
Edit the referenced Bunny lop-rabbit app-icon master into ONLY the BACKGROUND LAYER for a tvOS parallax app icon. Create a wide 5:3 landscape composition intended for an 800 x 480 tvOS icon layer. Remove the rabbit completely and naturally reconstruct the space behind it. Keep the same deep midnight-navy background, restrained violet and electric-blue flowing light ribbons, tiny soft particles, and cinematic lighting. The center must remain calm enough for a foreground rabbit layer. No animal, no text, no logo, no play symbol, no watermark, no border, no rounded-corner mask. Fill every pixel; opaque PNG appearance. Preserve generous safe margins for tvOS focus scaling.
```

The foreground was generated on a uniform chroma background so the rabbit
could be converted into a real transparent PNG layer:

```text
Create the tvOS FOREGROUND layer from the referenced Bunny rabbit master. Wide 5:3 landscape, one centered head-and-upper-body portrait of the same normal friendly orange-brown lop-eared rabbit, natural anatomy, two drooping ears, plain face, symmetrical eyes, normal nose and muzzle, warm key light and subtle cool rim light. Keep the whole rabbit comfortably within a generous parallax safe zone. Place it against a perfectly flat, uniform, fully saturated pure chroma-key green background (#00FF00) with no checkerboard, no gradient, no texture, no shadows on the background, and no green objects on the rabbit. Clean crisp silhouette and fine fur edges. No text, logo, symbol, costume, watermark, border, or rounded mask.
```

The accepted generated source IDs are
`exec-29b3fcf9-bcb7-4b7f-865c-2a250370b4d4` for the background and
`exec-8dc769f6-b703-4bf1-a3c3-771c319468f1` for the rabbit. The source images
were resized with Lanczos filtering. The uniform green was removed with a
chroma key, a one-pixel alpha erosion, a light edge blur, and green-spill
suppression before the 1280 x 768 and 400 x 240 layers were written. The final
two-layer compositions were inspected at 1280 x 768 and are compiled by the
tvOS asset catalog rather than shipped as a pre-masked flat icon.

## Profile generation briefs

Each profile used the same visual system: one centered, friendly animal portrait
on a simple midnight-navy background with restrained violet and blue light,
soft realistic 3D materials, a clear silhouette at small sizes, and no text,
logos, symbols, costume, border, watermark, celebrity likeness, or copyrighted
character. The subject line changed for each generation:

```text
Create an original square profile avatar of one friendly red panda with natural anatomy and a plain expressive face.
Create an original square profile avatar of one friendly arctic fox with natural anatomy and a plain expressive face.
Create an original square profile avatar of one friendly golden retriever puppy with natural anatomy and a plain expressive face.
Create an original square profile avatar of one friendly orange-brown lop-eared rabbit with two naturally drooping ears, natural anatomy, and a plain expressive face.
Create an original square profile avatar of one friendly sea otter with natural anatomy and a plain expressive face.
Create an original square profile avatar of one friendly tabby kitten with natural anatomy and a plain expressive face.
```

These six lines are retained briefs, not a verbatim export of service-side
prompt metadata. The generated source IDs were, respectively:
`exec-05b85795-6c2d-42ef-8cd5-db457c13ee82`,
`exec-c3397424-19ae-455c-9e22-e14ce3f68da9`,
`exec-ebc0afa6-748f-43db-9493-724a4163a029`,
`exec-785424e0-b829-4695-bcbc-2067852d0e96`,
`exec-744f81de-9338-43f9-8372-ab591882a58b`, and
`exec-56366c64-57cc-4362-bc9b-cb61d7c63746`.
