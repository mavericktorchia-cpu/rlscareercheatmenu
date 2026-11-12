#!/usr/bin/env bash
# Packages the mod into cold_start.zip. Drop that zip into your BeamNG user folder's mods/ directory.
set -euo pipefail
cd "$(dirname "$0")"
rm -f cold_start.zip
zip -r -X cold_start.zip lua scripts ui >/dev/null
echo "Built $(pwd)/cold_start.zip"
