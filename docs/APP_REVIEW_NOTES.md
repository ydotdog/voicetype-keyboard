# App Review Notes

Paste the relevant parts into App Store Connect → App Review Information → Notes.
These notes explain the permissions reviewers commonly question and how to test
the keyboard transcription flow end to end.

## How to test (no purchase required)

1. Launch VoiceType and tap **Sign in with Apple**.
2. On first sign-in the account is granted a **one-time welcome credit** (about
   100,000 credits, ~US$0.10), which is enough to transcribe several short clips.
   No in-app purchase is required to evaluate the core feature.
3. On the Home tab, tap the record control and speak; the transcript appears and
   the balance is debited.

To test the **keyboard** (this is the main feature and is not obvious):

1. In VoiceType, turn on **keyboard mic** and complete **keyboard setup**
   (Settings → VoiceType keyboard) — add the VoiceType keyboard in iOS Settings
   and enable **Allow Full Access**.
2. Leave VoiceType running and switch to any app with a text field (e.g. Notes).
3. Switch to the **VoiceType keyboard** and tap it once to start capturing a clip,
   then tap again to stop.
4. The transcript is produced by VoiceType and inserted into the text field.

## Why the keyboard needs Full Access

iOS custom keyboards cannot use the microphone directly. VoiceType captures audio
in the **containing app** and shares the resulting transcript with the keyboard
through an App Group container. The keyboard requests **Full Access** only to read
that shared transcript (and the shared recording state) so it can insert text. The
keyboard does not send keystrokes or typing data to our servers.

## Why the app declares the audio background mode (Guideline 2.5.4)

The transcription feature spans two processes: the keyboard marks what to
transcribe while the user is in another app, and the containing app must keep its
audio session alive to capture that speech. The app therefore uses the `audio`
background mode. Recording is user-initiated: the user explicitly turns on
keyboard mic, and can choose a session length of 5 minutes, 12 hours, or until
manually stopped. Audio is used only for transcription and is streamed to the
backend, not stored as audio files by default.

## Sign in with Apple

Authentication is **Sign in with Apple** only. The app sends Apple's identity
token (and, when available, the authorization code) to the backend, which verifies
it and issues a session token.

## Account deletion (Guideline 5.1.1(v))

Account deletion is available in-app at **Settings → Delete account** with a
confirmation prompt. It permanently deletes the user's account, remaining credit,
transcription history, and stored purchase records, and revokes the app's Sign in
with Apple token grant on the server.

## Data and privacy

- No third-party advertising or analytics SDKs are integrated.
- The app does not track users across other apps or websites.
- Speech-to-text processing is performed by OpenAI on audio the user submits.
- Privacy manifests are included for the app and the keyboard extension; the only
  required-reason API used is `UserDefaults` (App Group container access, reason
  CA92.1; the app also accesses its own defaults, reason 1C8F.1).

## In-app purchases

Credits are **consumable** StoreKit products. The backend verifies each StoreKit
transaction (strict signature verification) and binds it to the signed-in account
via `appAccountToken`. Unfinished or interrupted purchases are reconciled on
relaunch/sign-in.
