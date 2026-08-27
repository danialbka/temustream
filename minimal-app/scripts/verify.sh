#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

"$ROOT_DIR/scripts/test.sh"
"$ROOT_DIR/scripts/build-tvos.sh" --typecheck
"$ROOT_DIR/scripts/build-watchos.sh" --typecheck
"$ROOT_DIR/scripts/build-simulator.sh"
"$ROOT_DIR/scripts/build-device.sh"

REFERENCE_IPA="${SKELETON_REFERENCE_IPA:-$ROOT_DIR/../artifacts/stremio_iOS-2.0.3-18.ipa}"
if [ -f "$REFERENCE_IPA" ]; then
  "$ROOT_DIR/scripts/benchmark-player-footprint.sh" "$REFERENCE_IPA"
else
  echo "Player footprint comparison SKIP (set SKELETON_REFERENCE_IPA to a reference IPA)"
fi

"$ROOT_DIR/scripts/benchmark-catalog-paging.sh"
"$ROOT_DIR/scripts/e2e-simulator.sh"
"$ROOT_DIR/scripts/ui-state-screenshots.sh"

echo "TemuStremio verification workflow PASS"
