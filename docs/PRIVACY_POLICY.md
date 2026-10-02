# VoiceType Privacy Policy

_Last updated: 2026-10-02_

VoiceType is provided by Apeonwheels Inc. ("we"). The app turns your speech into text. This policy explains what
we collect, why, who processes it, and how you can delete it.

Public URL: https://apeonwheels.com/voicetype/privacy/

## Summary

- We do **not** track you across other apps or websites.
- We do **not** sell your data or share it with data brokers or advertisers.
- You can delete your account from inside the app at any time (Settings → Delete
  account). Limited backups, operational logs, and a welcome-credit abuse-prevention
  marker may remain as described below.

## What we collect and why

| Data | Why | Linked to you | Kept |
| --- | --- | --- | --- |
| Apple account identifier and email (from Sign in with Apple) | Create and sign in to your account | Yes | Until account deletion from the active service; backup exceptions are described below |
| Name (only if you choose to share it at sign-in) | Personalize your account | Yes | Until account deletion from the active service; backup exceptions are described below |
| Audio you record | Sent to our transcription provider to produce text | Yes, in transit | Processed transiently on our server; unfinished or failed recordings are saved privately on your device for retry |
| Transcribed text | Returned to you and shown in your history | Yes | Until account deletion from the active service; backup exceptions are described below |
| Purchase records (StoreKit transaction identifiers) | Verify credit purchases and prevent duplicate grants | Yes | Until account deletion from the active service; backup and log exceptions are described below |
| Operational event logs, which may include account and transaction identifiers and event times | Service operation, security, and billing troubleshooting | Yes, when identifiers are present | Until logs rotate or are deleted; account deletion does not immediately remove them |
| Keyed hash of Apple account identifier and first welcome-credit grant time | Prevent repeated welcome-credit claims after account deletion | Pseudonymous | Retained after account deletion while the welcome-credit program operates |

We never ask for your Apple password. Sign in with Apple lets you hide your email
with Apple's private relay; we support that.

## How transcription works

When you record, the app keeps an audio session active so the VoiceType keyboard
can mark the speech to transcribe. Audio is sent over an encrypted connection to
our backend, which forwards it to our speech-to-text provider, **OpenAI**, solely
to generate the transcript. Our server processes audio transiently without retaining
audio files. While keyboard mic is on, the app continuously records temporary
audio on your device. Only clips you actively start are submitted for transcription.
A clip can finish when you tap to finish, turn off the microphone, reach a clip
or session time limit, or encounter an audio interruption. Idle audio files are
periodically replaced and are not uploaded. The resulting transcript is stored in your account so you can
reuse it and is cached in a shared container on your device so the keyboard can
insert it into the current text field.

Unfinished or failed recordings are saved separately in the app's private device
storage so you can retry from History after a connection failure or app restart.
Each saved recording is excluded from device backups and is removed after its
successful transcription, when you delete it from History, when you explicitly
sign out, or after account deletion. An expired login preserves these recordings
for the same account to recover after signing in again; signing in to a different
account removes them. New recordings do not replace older failed recordings.

## Language preferences and personal vocabulary

Language choices and vocabulary are saved per account on this device. You can add
names and phrases, or review and save a spelling suggested when you correct a
transcript in History. We do not learn from text typed in other apps. Up to 50
recent words and your language choices accompany each recording sent to our
backend and OpenAI. These hints are processed transiently, not stored as a
server-side vocabulary profile. A failed recording retains its original hints
until it is transcribed or deleted. You can disable learning and remove individual
words or clear the vocabulary in Settings. Signing out keeps this device's
preferences for the same account; deleting the account removes them here.
History corrections are local edits and do not update the server transcript.

## Third parties

- **Apple** — Sign in with Apple (authentication) and the App Store (payments).
- **OpenAI** — speech-to-text processing of the audio, language choices, and
  vocabulary hints you submit. Its processing is subject to its
  [API data practices](https://openai.com/enterprise-privacy/). Our statement
  that we do not retain audio files describes our own application server, not a
  guarantee about a provider's independent retention practices.
- **Google Cloud** — hosting our application server and account database in the
  United States.

We do not integrate advertising or analytics SDKs.

## Microphone and Full Access

- **Microphone:** after you turn on keyboard mic, recording continues while you
  use other apps until you turn it off or the selected session duration ends.
  Only clips you actively start are sent for transcription; a time limit,
  microphone shutdown, or audio interruption can also finish and submit a clip.
- **Keyboard Full Access:** the VoiceType keyboard requests Full Access so it can
  read the latest transcript from the app's shared container and insert it. The
  keyboard itself does not transmit your keystrokes to us.

## Data retention and deletion

Your account data is kept until you delete it. To delete your account:

1. Open VoiceType.
2. Go to **Settings → Delete account**.
3. Confirm.

This removes your user record, remaining credit, transcription history, and
stored purchase records from our active service, and revokes the app's Sign in
with Apple token grant. Restricted disaster-recovery backups may retain earlier
copies until those backups are replaced or deleted; they are not used to operate
your deleted account. Operational, security, and billing troubleshooting logs may
contain account and transaction identifiers and event times. Account deletion does
not immediately remove these logs; they remain until log rotation or deletion and
are not used to restore your deleted account. Deletion cannot be undone. Purchases already consumed are not
refundable through deletion; refunds are handled by Apple.

To prevent repeated welcome-credit claims, we retain only a keyed hash of your
Apple account identifier and the original grant time after deletion. This marker
contains no raw Apple identifier, email, name, or VoiceType account identifier.
It cannot restore your deleted account or content and is not used for advertising
or tracking. It remains while the welcome-credit program operates so the same
Apple identity cannot claim the first-use offer again.

When Apple refunds a credit pack, its credits are removed. If some were already
used, your balance may be negative and you need sufficient credit before
transcribing again. We never charge a payment method automatically. If Apple
reverses the refund, the removed credits are restored.

## Security and service operation

We use encrypted connections for requests between the app, our server, and our
transcription provider. Access to account data and backups is restricted to
authorized service administration. Network services necessarily receive
connection information such as an IP address when you connect. No transmission
or storage system can be guaranteed completely secure.

## Children

VoiceType is not directed to children under 13 and does not knowingly collect
their data.

## Changes

We may update this policy. Material changes will be reflected by the "Last
updated" date above.

## Contact

Questions or requests: **kq@apeonwheels.com**
