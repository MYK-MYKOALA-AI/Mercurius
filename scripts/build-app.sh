#!/bin/sh
# Builds a local developer app; never installs it or reads provider credentials.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$TASK_ROOT"
[ "$(uname -m)" = arm64 ] || { printf '%s\n' 'Requires an Apple Silicon Mac.' >&2; exit 1; }
: "${MERCURIUS_SIGNING_IDENTITY:?Set your own Apple Development or Developer ID Application signing identity.}"
[ "$MERCURIUS_SIGNING_IDENTITY" != - ] || { printf '%s\n' 'Use your own Apple signing identity; ad-hoc signing is not supported.' >&2; exit 1; }
for TASK_RESOURCE in Info.plist PrivacyInfo.xcprivacy AppIcon.icns Licences.txt cursus-clip.js Koa/pop_in.mov Koa/listen_calm.mov Koa/listen_loud.mov Koa/think.mov Koa/happy.mov Koa/oops.mov Koa/shrug.mov; do
    [ -f "Resources/$TASK_RESOURCE" ] && [ ! -L "Resources/$TASK_RESOURCE" ] || { printf '%s\n' "Missing or symlinked resource: $TASK_RESOURCE" >&2; exit 1; }
done
[ ! -L dist ] || { printf '%s\n' 'dist must not be a symlink.' >&2; exit 1; }
mkdir -p dist
TASK_OUTPUT=$(mktemp -d "$TASK_ROOT/dist/Mercurius.XXXXXXXX")
TASK_APP="$TASK_OUTPUT/Mercurius.app"
trap 'rm -rf "$TASK_OUTPUT"' EXIT HUP INT TERM
xcrun swift build --jobs 2 --configuration release --arch arm64 --product CursusVox
TASK_BIN=$(xcrun swift build --configuration release --arch arm64 --show-bin-path)
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources/Koa"
cp "$TASK_BIN/CursusVox" "$TASK_APP/Contents/MacOS/CursusVox"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
TASK_REVISION=source-archive
if [ "$(git rev-parse --show-toplevel 2>/dev/null || true)" = "$TASK_ROOT" ]; then
    TASK_REVISION=$(git rev-parse --short=12 HEAD)
    if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then TASK_REVISION="$TASK_REVISION-dirty"; fi
fi
/usr/libexec/PlistBuddy -c "Add :CursusSourceRevision string $TASK_REVISION" "$TASK_APP/Contents/Info.plist"
for TASK_RESOURCE in PrivacyInfo.xcprivacy AppIcon.icns Licences.txt cursus-clip.js Koa/pop_in.mov Koa/listen_calm.mov Koa/listen_loud.mov Koa/think.mov Koa/happy.mov Koa/oops.mov Koa/shrug.mov; do
    cp "Resources/$TASK_RESOURCE" "$TASK_APP/Contents/Resources/$TASK_RESOURCE"
done
plutil -lint "$TASK_APP/Contents/Info.plist" "$TASK_APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [ -n "${MERCURIUS_SIGNING_KEYCHAIN:-}" ]; then
    codesign --force --sign "$MERCURIUS_SIGNING_IDENTITY" --keychain "$MERCURIUS_SIGNING_KEYCHAIN" "$TASK_APP"
else
    codesign --force --sign "$MERCURIUS_SIGNING_IDENTITY" "$TASK_APP"
fi
codesign --verify --deep --strict "$TASK_APP"
trap - EXIT HUP INT TERM
printf '%s\n' "$TASK_APP"
