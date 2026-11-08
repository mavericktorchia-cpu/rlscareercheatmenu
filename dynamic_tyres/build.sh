#!/usr/bin/env bash
# Packages the mod into dynamic_tyres.zip. Drop that zip into your BeamNG user folder's mods/ directory.
set -euo pipefail
cd "$(dirname "$0")"
rm -f dynamic_tyres.zip
zip -r -X dynamic_tyres.zip lua scripts ui >/dev/null
echo "Built $(pwd)/dynamic_tyres.zip"
