#!/usr/bin/env bash
# Packages the mod into rls_cheat_menu.zip. Drop that zip into your BeamNG user folder's mods/ directory.
set -euo pipefail
cd "$(dirname "$0")"
rm -f rls_cheat_menu.zip
zip -r -X rls_cheat_menu.zip lua scripts ui >/dev/null
echo "Built $(pwd)/rls_cheat_menu.zip"
