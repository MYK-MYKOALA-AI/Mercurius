# Mercurius contributor guidance

Apple Silicon, macOS 26+, Swift 6.2 package manifest. CursusCore owns policy and cleanup rules; CursusVox/CursusPlatform adapt native APIs. Internal target names retain the project's CursusVox heritage.

Run `swift test --jobs 2 --no-parallel`, `python3 Tests/ScriptTests/public_export.test.py` and `python3 Tests/ScriptTests/build.test.py`, and `python3 scripts/check-public.py`. Use the existing build script with your own Apple signing identity. Do not install, launch a diagnostic mode or change a contributor's settings as part of tests.

Never commit credentials, private signing material, personal paths, recordings, logs or generated app bundles. Never read unrelated credentials. Local-only speech must not silently fall back to a network service. Keep event-tap callbacks nonblocking and preserve paste safety, focus revalidation, recording bounds and Reduce Motion.

Koa clips are transparent HEVC at 24 fps and decode to 144 px. Fixed frame counts: pop_in 12, listen_calm/listen_loud/think 48, happy/oops 19, shrug 14. Edit the Blender generator, regenerate and validate clips; keep generated .blend files untracked because Blender can retain workstation metadata.

MIT applies to original application code; artwork is CC BY 4.0 with trademarks reserved. Preserve THIRD-PARTY-NOTICES.md. Report automated checks, native checks and release status separately.
