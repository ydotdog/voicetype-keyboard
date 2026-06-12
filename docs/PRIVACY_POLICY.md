# VoiceType Privacy Policy

_Last updated: 2026-06-13_

VoiceType ("the app", "we") turns your speech into text. This policy explains what
we collect, why, who processes it, and how you can delete it.

Public URL: https://voicetype.y.dog/privacy

## Summary

- We do **not** track you across other apps or websites.
- We do **not** sell your data or share it with data brokers or advertisers.
- You can delete your account and all associated data from inside the app at any
  time (Settings → Delete account).

## What we collect and why

| Data | Why | Linked to you | Kept |
| --- | --- | --- | --- |
| Apple account identifier and email (from Sign in with Apple) | Create and sign in to your account | Yes | Until you delete your account |
| Name (only if you choose to share it at sign-in) | Personalize your account | Yes | Until you delete your account |
| Audio you record | Sent to our transcription provider to produce text | Yes, in transit | Streamed for processing; not retained as audio files by default |
| Transcribed text | Returned to you and shown in your history | Yes | Until you delete your account |
| Purchase records (StoreKit transaction identifiers) | Verify credit purchases and prevent duplicate grants | Yes | Until you delete your account |

We never ask for your Apple password. Sign in with Apple lets you hide your email
with Apple's private relay; we support that.

## How transcription works

When you record, the app keeps an audio session active so the VoiceType keyboard
can mark the speech to transcribe. Audio is sent over an encrypted connection to
our backend, which forwards it to our speech-to-text provider, **OpenAI**, solely
to generate the transcript. Audio is processed transiently and is not stored as
files by default. The resulting transcript is stored in your account so you can
reuse it and is cached in a shared container on your device so the keyboard can
insert it into the current text field.

## Third parties

- **Apple** — Sign in with Apple (authentication) and the App Store (payments).
- **OpenAI** — speech-to-text processing of the audio you submit.

We do not integrate advertising or analytics SDKs.

## Microphone and Full Access

- **Microphone:** used only to capture the speech you choose to transcribe.
- **Keyboard Full Access:** the VoiceType keyboard requests Full Access so it can
  read the latest transcript from the app's shared container and insert it. The
  keyboard itself does not transmit your keystrokes to us.

## Data retention and deletion

Your account data is kept until you delete it. To delete everything:

1. Open VoiceType.
2. Go to **Settings → Delete account**.
3. Confirm.

This permanently removes your user record, remaining credit, transcription
history, and stored purchase records, and revokes the app's Sign in with Apple
token grant. Deletion cannot be undone. Purchases already consumed are not
refundable through deletion; refunds are handled by Apple.

## Children

VoiceType is not directed to children under 13 and does not knowingly collect
their data.

## Changes

We may update this policy. Material changes will be reflected by the "Last
updated" date above.

## Contact

Questions or requests: **kq@apeonwheels.com**
