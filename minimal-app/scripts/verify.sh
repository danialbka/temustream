#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

"$ROOT_DIR/scripts/test.sh"
"$ROOT_DIR/scripts/build-simulator.sh"
"$ROOT_DIR/scripts/build-device.sh"
"$ROOT_DIR/scripts/benchmark-player-footprint.sh"
"$ROOT_DIR/scripts/benchmark-catalog-paging.sh"
"$ROOT_DIR/scripts/e2e-simulator.sh"
"$ROOT_DIR/scripts/ui-state-screenshots.sh"

echo "Skeleton verification workflow PASS"
