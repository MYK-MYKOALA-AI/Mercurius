# Contributing

Mercurius is an early native macOS project. Report reproducible problems and send small pull requests. Say which Mac, macOS, Swift toolchain, speech provider and editor you tested. Remove transcripts, recordings, keys and personal screenshots from reports.

Run `swift test --jobs 2 --no-parallel`, `python3 Tests/ScriptTests/public_export.test.py` and `python3 Tests/ScriptTests/build.test.py` and `python3 scripts/check-public.py`. Native fixtures share AppKit and the main actor, so keep the Swift tests serial. Unit tests do not prove physical shortcuts, microphones, Accessibility insertion or recognition quality. Record those separately.

Keep policy in CursusCore and platform mechanics in CursusVox/CursusPlatform. Keep native paste safety, recording limits, credential handling and Reduce Motion intact. Do not add a network fallback to an explicitly local mode.

Never commit keys, .env files, Keychain exports, signing certificates/private keys, real recordings, application builds, logs or private machine paths. Contributor signing uses your own Apple identity. No default private signing account is provided. Do not widen CI permissions or upload private diagnostics as a convenience.

By contributing original code, you agree to license it under MIT. Original contributed artwork must identify its origin and licence; do not assume a picture found online is free to reuse. Existing artwork and third-party notices retain their separate terms.
