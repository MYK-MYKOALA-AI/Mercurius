#!/bin/sh
# Rebuilds Resources/AppIcon.icns from Design/Brand/Mercurius.png. Run from the repo root.
set -eu
TASK_WORK=$(mktemp -d); trap 'rm -rf "$TASK_WORK"' EXIT
swift scripts/make-icon.swift "$TASK_WORK/icon.png"
mkdir "$TASK_WORK/AppIcon.iconset"
for TASK_SIZE in 16 32 128 256 512; do
    sips -z $TASK_SIZE $TASK_SIZE "$TASK_WORK/icon.png" --out "$TASK_WORK/AppIcon.iconset/icon_${TASK_SIZE}x${TASK_SIZE}.png" >/dev/null
    TASK_DOUBLE=$((TASK_SIZE * 2))
    sips -z $TASK_DOUBLE $TASK_DOUBLE "$TASK_WORK/icon.png" --out "$TASK_WORK/AppIcon.iconset/icon_${TASK_SIZE}x${TASK_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$TASK_WORK/AppIcon.iconset" -o Resources/AppIcon.icns
python3 scripts/strip-artwork-metadata.py Resources/AppIcon.icns
cp "$TASK_WORK/icon.png" "${1:-/dev/null}" 2>/dev/null || true
