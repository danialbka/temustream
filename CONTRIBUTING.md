# Contributing

Thanks for helping improve Bunny. Small, focused changes are easiest to
review and safest to test across the three Apple platforms.

## Before you start

Search existing issues before opening a new one. For a bug, include the
platform, OS version, app version, selected player, and the smallest lawful test
case that reproduces it. Do not post credentials, private add-on URLs, signed
stream URLs, device identifiers, or full logs.

Security reports belong in the private route described in
[SECURITY.md](SECURITY.md).

## Local setup

```sh
git clone https://github.com/danialbka/temustream.git
cd temustream/minimal-app
brew install xcodegen rust ffmpeg
./scripts/test.sh
./scripts/build-simulator.sh
```

`minimal-app/project.yml` is the Xcode source of truth. Do not hand-edit the
generated `project.pbxproj`. Keep credentials and machine-specific settings in
ignored local files.

## Pull requests

- Explain the user-visible problem and why the chosen change solves it.
- Keep unrelated formatting or cleanup out of the same patch.
- Add or update tests for behavior changes.
- Preserve persisted identifiers and migrations unless the change includes a
  safe compatibility path.
- Use public-domain media and fictional names in fixtures and screenshots.
- Run `./scripts/public-release-check.sh` from the repository root and the
  relevant tests under `minimal-app/scripts/`.
- Note what was verified on source, simulator, Apple TV, Apple Watch, or a
  physical device. These are different kinds of evidence.

By contributing, you agree that your original contribution may be distributed
under the repository's MIT License. Do not submit code, images, media, or other
material you do not have the right to contribute. Existing third-party code
keeps its original license.
