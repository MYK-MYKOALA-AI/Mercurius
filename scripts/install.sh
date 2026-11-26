#!/bin/sh
# One-command install from source: builds Mercurius, signs it with your own Apple identity and
# puts it in ~/Applications. Reads no provider keys and sends nothing anywhere. An older copy at
# ~/Applications/Mercurius.app goes to your Trash; nothing else is replaced.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$TASK_ROOT"
say() { printf '%s\n' "$*" >&2; }
[ "$(uname -m)" = arm64 ] || { say 'Mercurius needs an Apple Silicon Mac.'; exit 1; }
TASK_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$TASK_MAJOR" -ge 26 ] 2>/dev/null || { say 'Mercurius needs macOS 26 or later.'; exit 1; }
xcrun --find swift >/dev/null 2>&1 || {
    say 'Install Xcode from the App Store, open it once to finish setup, then run this again.'
    exit 1
}
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
TASK_APP=$(sh scripts/build-app.sh | tail -n 1)
[ -d "$TASK_APP" ] || { say 'The build did not produce an app.'; exit 1; }
TASK_DEST="$HOME/Applications/Mercurius.app"
mkdir -p "$HOME/Applications"
if [ -e "$TASK_DEST" ] || [ -L "$TASK_DEST" ]; then
    # Quit only the copy installed here, never another app that shares the executable name.
    if pgrep -f "$TASK_DEST/Contents/MacOS/" >/dev/null 2>&1; then
        osascript -e 'tell application id "au.com.mykoala.mercurius" to quit' >/dev/null 2>&1 || true
        sleep 2
    fi
    mkdir -p "$HOME/.Trash"
    mv "$TASK_DEST" "$HOME/.Trash/Mercurius $(date +%Y-%m-%d-%H%M%S).app"
fi
ditto "$TASK_APP" "$TASK_DEST"
rm -rf "$(dirname -- "$TASK_APP")"
codesign --verify --strict "$TASK_DEST"
printf '%s\n' "Installed $TASK_DEST"
if [ "${MERCURIUS_NO_OPEN:-}" != 1 ]; then
    open "$TASK_DEST"
    printf '%s\n' 'Mercurius is open. Follow setup to allow the microphone and Accessibility, then add your own keys.'
fi
