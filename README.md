# Mercurius

**Free, open-source dictation for your Mac. Bring your own keys.**

Mercurius is a native macOS dictation app from [MyKoala](https://mykoala.com.au). It is being built as an independent alternative to paid dictation subscriptions: speak where you already write, choose how your words are processed, and use your own provider account when you want cloud models.

[Website](https://mercurius.mykoala.com.au/) · [MyKoala](https://mykoala.com.au)

> **Public repository status:** this repository contains the project README only. We are testing the app locally before publishing its source or downloads. No application code, binaries or development history have been uploaded here.

## The idea

Dictation should be a tool you control. Mercurius is intended to be free software, with no required Mercurius subscription and no MyKoala account needed for dictation.

Use on-device speech when you want your audio and text to stay on your Mac. Or connect your own OpenRouter or supported provider key and pay that provider directly for the models you choose. You decide whether cloud recognition or cloud text cleanup is useful for your work.

**Free software does not mean free cloud inference.** Provider usage charges, credit balances, rate limits and retention policies still apply. There is no promise that every model or free endpoint will be available to every key.

## What it is designed to do

These features are implemented in the private development build and are undergoing local validation. They are not a claim that a public release is ready.

- **Dictate into Mac apps.** Hold your configured shortcut, speak, then release it to finish. Mercurius delivers the resulting text into the app you are using.
- **See recognition progress.** A small recording panel shows listening and processing state, with local live-word preview where an installed recognizer supports it.
- **Choose the speech engine.** Use Apple on-device speech, supported OpenRouter transcription routes, or the direct ElevenLabs Scribe integration.
- **Make cleanup optional.** Keep recognition separate from optional cloud text cleanup. Choose a writing style for each app and decide whether to remove filler words or tidy punctuation.
- **Keep your vocabulary.** Add names, project terms and explicit spelling replacements. Provider hint support and limits vary.
- **Reuse phrases.** Save snippets that can expand when the whole recording matches their cue.
- **Review and recover.** Use recent Activity, copy results and retry supported operations rather than losing the words after a failed insertion.
- **Rewrite or translate deliberately.** Generate a cloud preview, review it, then choose whether to copy or replace the selected text.
- **See usage.** Show provider-reported charges when available, with approximate or separate credit accounting when an exact dollar charge is unavailable.

Native editor support, shortcuts, microphone behaviour and recovery are being tested on real Macs. A passing unit test is not a guarantee that every editor or microphone setup works.

## Bring your own keys

The integrations currently being validated are:

| Route | What you provide | What runs remotely |
| --- | --- | --- |
| Apple on-device speech | No API key; installed macOS speech assets and the relevant permissions | No speech processing or text cleanup when cloud cleanup is off |
| OpenRouter | Your own OpenRouter API key | Selected supported cloud transcription and/or text cleanup |
| Direct ElevenLabs Scribe | Your own ElevenLabs API key | Audio transcription; optional OpenRouter cleanup uses a separate OpenRouter key |

OpenRouter provides access to different providers and models through one account. A model appearing in a catalogue does not guarantee that the current adapter, your account permissions or your balance can run it.

Mercurius does not require sending provider keys to a MyKoala server. The native build stores saved keys in this Mac's Keychain. Saving a key is an explicit action; it does not itself prove that the provider connection, credit balance or transcription works.

We are not publishing sample credentials, shared API accounts or an inference proxy.

## “Runs locally” and “processed locally” are different

The app runs on your Mac. Where recognition and cleanup happen depends on the mode you select.

| Mode | Audio | Transcript/text | Per-call API cost |
| --- | --- | --- | --- |
| On-device speech, cloud cleanup off | Stays on your Mac | Stays on your Mac | None |
| On-device speech with cloud cleanup | Stays on your Mac | Sent to the selected cleanup service | Cleanup provider charges may apply |
| Cloud speech | Sent to the selected speech provider | Returned to your Mac; optional cleanup may send it to a cleanup provider | Speech and any cleanup charges may apply |

For **fully local dictation**, choose on-device speech and switch cloud cleanup off. Features that explicitly generate cloud previews, such as AI rewrite or translation, also need to remain unused for that workflow to stay local.

Setup may require downloading chosen macOS speech assets. The app can fetch public model and price metadata without sending dictation content. Local mode is a statement about audio and text processing, not a promise that the application never makes any network request.

Cloud providers have their own retention and data-use policies. Vocabulary hints, dictionary keyterms or cleanup context can accompany the relevant requests. A zero-price model is not automatically a private model.

## Local data and permissions

Mercurius is designed around local application storage, scoped Keychain credentials and explicit permission setup.

Microphone permission allows recording. Speech Recognition permission applies to the local speech features that need it. Accessibility and the selected shortcut permissions support delivery into other apps. Additional capture tools can request their own relevant permissions when used.

Recent dictation text is short-lived; saved vocabulary, snippets and captured library items have their own local persistence. Do not assume every feature uses the same retention period.

The current build includes guarded delivery rules for secure fields and excluded applications. These boundaries still require real-world verification before public release.

## What “free” means

- The intended app model is free software, without a required app subscription.
- On-device recognition with cloud cleanup off has no per-call API charge.
- Cloud speech and cleanup use your own provider accounts and allowances.
- Provider costs are separate from the app. Mercurius cannot promise free credits, unlimited usage or permanently free models.
- Usage displays are informative; do not treat them as a provider-side spending cap.

No subscription tiers, hosted inference plan or commercial pricing is being announced here.

## Platform and current limits

The current development target is **Apple Silicon Macs running macOS 26 or later**.

The build is focused on short, everyday dictation. Current constraints include a 60-second recording limit, English-focused cloud adapters and varying editor support. On-device languages depend on installed macOS assets. There is no Windows, Linux, iOS or Android release, account sync or meeting-transcription product in this repository.

We have not established that Mercurius is more accurate or faster than every paid dictation app. Accuracy, latency, memory use and cost need to be compared on the same real speech and hardware.

## Publication and testing

The public repository is intentionally limited to this README while local testing continues.

Before application source is published, we are validating:

- Recording, stopping, cancellation and shortcut behaviour.
- Real-editor insertion, clipboard fallback and duplicate prevention.
- Local speech availability, cloud errors, retries and recovery.
- Keychain access, privacy boundaries and permission handling.
- Vocabulary, snippets, cleanup and literal/code preservation.
- Latency, memory, audio quality and provider costs on comparable samples.
- Packaging, signatures, dependency/asset licences and repository history.

The goal is a useful, inspectable release. There is no public installer, build command or release date yet. We will publish selected source and release material after local qualification and an explicit publication decision.

## Open-source licence

Mercurius is intended to be released under an open-source licence. The licence will be included with the application source release; the choice has not been finalised.

A public README is not a source release or a licence grant for unpublished application code.

## Following the project

Visit [mercurius.mykoala.com.au](https://mercurius.mykoala.com.au/) or watch this repository for updates. Keep API keys, transcripts, private recordings and personal data out of public issues.

Built by [MyKoala](https://mykoala.com.au), Australia.
