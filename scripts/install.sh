#!/bin/sh
# One-command install from source: builds Mercurius, signs it with your own Apple identity and
# puts it in ~/Applications. The script reads no API keys and uploads nothing. It replaces only a
# previous Mercurius build at ~/Applications/Mercurius.app (checked by bundle ID), which goes to
# your Trash after the new copy is verified.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$TASK_ROOT"
TASK_BUNDLE_ID=au.com.mykoala.mercurius
say() { printf '%s\n' "$*" >&2; }
[ "$(uname -m)" = arm64 ] || { say 'Mercurius needs an Apple Silicon Mac.'; exit 1; }
TASK_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$TASK_MAJOR" -ge 26 ] 2>/dev/null || { say 'Mercurius needs macOS 26 or later.'; exit 1; }
xcrun --find swift >/dev/null 2>&1 || {
    say 'Install Xcode from the App Store, open it once to finish setup, then run this again.'
    exit 1
}
TASK_DEST="$HOME/Applications/Mercurius.app"
TASK_EXECUTABLE="$TASK_DEST/Contents/MacOS/CursusVox"
if [ -L "$TASK_DEST" ] || { [ -e "$TASK_DEST" ] && [ ! -d "$TASK_DEST" ]; }; then
    say "$TASK_DEST is not a Mercurius build; move it away and run this again."
    exit 1
fi
if [ -d "$TASK_DEST" ]; then
    TASK_EXISTING=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TASK_DEST/Contents/Info.plist" 2>/dev/null || true)
    [ "$TASK_EXISTING" = "$TASK_BUNDLE_ID" ] || {
        say "$TASK_DEST is not a Mercurius build; move it away and run this again."
        exit 1
    }
fi
if [ -z "${MERCURIUS_SIGNING_IDENTITY:-}" ]; then
    # Your own certificate, found by its fingerprint. A free Apple ID in Xcode is enough.
    TASK_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    for TASK_KIND in 'Apple Development' 'Developer ID Application'; do
        TASK_FOUND=$(printf '%s\n' "$TASK_IDENTITIES" | sed -n "s/^ *[0-9][0-9]*) \([0-9A-F]\{40\}\) \"$TASK_KIND: .*\"\$/\1/p")
        TASK_COUNT=$(printf '%s' "$TASK_FOUND" | grep -c . || true)
        if [ "$TASK_COUNT" -eq 1 ]; then
            MERCURIUS_SIGNING_IDENTITY=$TASK_FOUND
            break
        elif [ "$TASK_COUNT" -gt 1 ]; then
            say "You have more than one $TASK_KIND certificate. Pick one and run:"
            say "  MERCURIUS_SIGNING_IDENTITY=<fingerprint> sh scripts/install.sh"
            printf '%s\n' "$TASK_IDENTITIES" | grep "\"$TASK_KIND: " >&2 || true
            exit 1
        fi
    done
    [ -n "${MERCURIUS_SIGNING_IDENTITY:-}" ] || {
        say 'No Apple signing certificate found. Make a free one in about a minute:'
        say '  Xcode > Settings > Accounts > add your Apple ID > Manage Certificates > + > Apple Development'
        say 'Then run this again.'
        exit 1
    }
    export MERCURIUS_SIGNING_IDENTITY
fi
TASK_BUILT=$(sh scripts/build-app.sh)
TASK_APP=$(printf '%s\n' "$TASK_BUILT" | tail -n 1)
[ -d "$TASK_APP" ] || { say 'The build did not produce an app.'; exit 1; }
# Stage next to the destination and verify there, so a failed copy never touches the installed app.
mkdir -p "$HOME/Applications"
TASK_STAGE=$(mktemp -d "$HOME/Applications/.Mercurius-install.XXXXXXXX")
trap 'rm -rf "$TASK_STAGE"' EXIT HUP INT TERM
ditto "$TASK_APP" "$TASK_STAGE/Mercurius.app"
codesign --verify --strict "$TASK_STAGE/Mercurius.app"
rm -rf "$(dirname -- "$TASK_APP")"
if [ -d "$TASK_DEST" ]; then
    # Quit only processes running this exact installed executable.
    TASK_PIDS=$(ps -axo pid=,comm= | awk -v exe="$TASK_EXECUTABLE" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == exe) print pid }')
    if [ -n "$TASK_PIDS" ]; then
        kill -TERM $TASK_PIDS 2>/dev/null || true
        TASK_WAIT=0
        while [ "$TASK_WAIT" -lt 10 ] && ps -axo comm= | grep -Fqx "$TASK_EXECUTABLE"; do
            sleep 1
            TASK_WAIT=$((TASK_WAIT + 1))
        done
        if ps -axo comm= | grep -Fqx "$TASK_EXECUTABLE"; then
            say 'Mercurius is still running. Quit it from the menu bar and run this again.'
            exit 1
        fi
    fi
    mkdir -p "$HOME/.Trash"
    mv "$TASK_DEST" "$HOME/.Trash/Mercurius $(date +%Y-%m-%d-%H%M%S)-$$.app"
fi
mv "$TASK_STAGE/Mercurius.app" "$TASK_DEST"
printf '%s\n' "Installed $TASK_DEST"
if [ "${MERCURIUS_NO_OPEN:-}" != 1 ]; then
    open "$TASK_DEST"
    printf '%s\n' 'Mercurius is open. Follow setup to allow the microphone and Accessibility, then add your own keys.'
fi
