#!/bin/zsh
# Renders docs/menubar.png from the real MenuBarBattery drawing code.
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"
swiftc -O scripts/render-menubar/main.swift Sources/BatteryOracle/Views/MenuBarBattery.swift -o "$T/render"
"$T/render" docs/menubar.png
rm -rf "$T"
