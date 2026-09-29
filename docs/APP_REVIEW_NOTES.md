# App Review Notes

The draft below reflects the current source UI. Complete the internal evidence
checks before copying the reviewer-facing section into App Store Connect.

## Reviewer-facing draft

### Guideline 2.5.4 — background dictation

The background audio feature is voice dictation through the VoiceType keyboard
while another app is in the foreground. Open VoiceType manually from the Home
Screen, then use **Home → Turn on keyboard mic**. The keyboard extension does not
launch the containing app. The user manually returns to the original app.
Home explains the microphone behavior. Setup instructions are available
before signing in through **How to set up
and use the keyboard**, and after signing in through **Settings → VoiceType
keyboard**.

### Test on iPhone or iPad

1. Launch VoiceType and use **Sign in with Apple**. An Apple Account signed in on
   the device and an internet connection are required. Confirm the **Credit** balance
   has credit for a short transcription.
2. In the device's **Settings → General → Keyboard → Keyboards → Add New
   Keyboard**, select **VoiceType**. Open its entry in the Keyboards list and
   enable **Allow Full Access**.
3. Open VoiceType manually and tap **Turn on keyboard mic**. Read the cloud
   transcription disclosure and choose **Allow cloud transcription**. Tap
   **Turn on keyboard mic** again, then allow the system microphone prompt.
   Home displays **Keyboard mic on**. If permission was previously denied,
   enable VoiceType's microphone permission in device Settings and try again.
4. Open Apple Notes, focus an editable note and select VoiceType using the
   globe/input mode control. Notes remains in the
   foreground while VoiceType is in the background. The keyboard microphone icon
   is now filled, indicating readiness.
5. Tap the **microphone icon**, say a short sentence, and tap the **waveform** to finish. The keyboard displays
   **Transcribing**. Keep that same text field open until the text is inserted.
6. Return to VoiceType. The result is also in **History**. On Home, tap
   **Turn off keyboard mic**. During an active clip, this control
   reads **Finish clip & turn off mic** and finishes the clip before ending the
   session.

Full Access is required for this path. If the selected session ends, open VoiceType manually
and enable a new session. The keyboard explains these steps.
Secure fields
and apps that disallow third-party keyboards use the system keyboard; an ordinary
note in Apple Notes is suitable for this test.

### Purpose and control of background audio

The user explicitly enables the microphone in the containing app because custom
keyboards cannot access it directly. The microphone stays active between clips
for the selected session. Only segments started with the **microphone icon** are submitted for
transcription; temporary idle audio is rotated and discarded locally.

**Session length** offers **5 min**, **12 hr**, and **Forever**, with **5 min** as
the default. A previously saved selection is used when starting the microphone. These limit the keyboard microphone session from its original start;
repeated activation and individual clips do not restart its timer. Individual
clips are limited to 10 minutes.
**Forever** means no app-defined session timer, not a guarantee against system
interruptions. Calls or audio interruptions can end a session; the user can enable
the microphone again from Home.

**Allow Full Access** enables the keyboard to exchange recording commands, state,
and transcripts with the containing app through their shared container. The
keyboard does not upload text typed in the host app.

Basic letters, numbers, spaces, punctuation, delete and return work without Full
Access, network access or cloud transcription consent. Tap **ABC** to show these
keys; they are shown automatically when Full Access is disabled. The system globe
or the keyboard's next-keyboard control switches input methods.

### Other review paths

- Privacy: **Settings → Cloud transcription** withdraws consent, stops an active
  microphone session, and prevents new uploads and retries. Privacy and support
  links are available before sign-in and in Settings.
- Failed transcription: **History** retains each failed recording with **Retry**
  and **Delete**. A failed recording does not block enabling the microphone or a new
  recording. Retry results remain in History for explicit copying.
- Credits: **Credit** contains consumable App Store packs. **Settings → Check
  purchases** checks unfinished purchases and refreshes the balance.
- Account deletion: **Settings → Delete account → Delete**. This requests permanent
  account deletion and revocation of the stored Apple sign-in authorization.
  Temporary revocation failures are shown so deletion can be retried.

### Physical-device demonstration

**PENDING — record and attach a demonstration of steps 1–6 on a physical device
using the submitted build. No demonstration recording or URL is available yet.**

## Internal release evidence — do not paste

- [ ] Replace the pending demonstration section with a verified attachment or
  accessible recording link. Record the actual device model, OS version, app
  version, and build number. Show microphone activation, Notes in the foreground,
  microphone icon → waveform → inserted text, and ending the microphone session.
- [ ] Verify fresh-account welcome credit on the deployed backend. Its source
  default is 100,000 credits, but production may override or disable it. Do not
  promise a value or purchase-free review until confirmed. Ensure the reviewer
  can test a short clip without purchasing.
- [ ] Test the exact submitted build using these steps, including the iPad flow
  involved in the previous rejection. Keep results separate from this draft.
- [ ] Confirm the deployed backend and App Store credit packs are available for
  the review build. Attach only evidence actually obtained.
