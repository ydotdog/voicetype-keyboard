# App Review Notes

The reviewer-facing text is in [APP_REVIEW_NOTES_SUBMISSION.txt](APP_REVIEW_NOTES_SUBMISSION.txt).
That file reflects the product restored to the build 27 baseline (`eaa91c3`).
It does not claim the offline typing keys or cloud-consent controls added in
builds 28–29. Company website links use the VoiceType section of
`apeonwheels.com`.

## Source-checked review flow

1. Sign in with Apple and confirm enough credit for a short transcription.
2. Add the VoiceType keyboard in system Settings and enable Allow Full Access.
3. In an editable Apple Note, select VoiceType and tap its outlined microphone.
   This opens VoiceType and enables its microphone. Grant the system microphone
   permission if shown. Home displays **Ready for the keyboard**.
4. Visit the **Home Screen**, then return manually to the same Note and keyboard.
   This explicit Home Screen step is required for the requested background-audio
   demonstration.
5. Tap the keyboard microphone to begin a clip and the waveform to finish.
   Keep the same text field open until the transcription is inserted.
6. Return to VoiceType, check History, and tap **Turn off keyboard mic** on Home.
   The button keeps this label during a clip; stopping then finishes and
   transcribes the clip. Home displays **Microphone off** when stopped.

The saved session duration is reused on activation from the keyboard. Options are
**5 min** (default), **12 hr**, and **Forever**. Clips do not restart the session
timer; an individual clip is limited to 10 minutes. Forever has no app timer but
does not prevent iOS interruptions.

The containing app maintains its audio session while another app is in the
foreground. Idle audio is rotated and discarded locally. Recorded clips, selected
languages and vocabulary hints are sent through VoiceType's server to OpenAI.
Full Access is needed for commands and transcript exchange through the shared
container. Text typed in the host app is not uploaded by the keyboard.

## Evidence and release checks — not reviewer-facing copy

- [ ] Verify the exact build selected in App Store Connect, including its physical
  keyboard-to-app activation and text insertion. The source baseline alone does
  not prove a particular installed build works.
- [ ] Verify **Turn off keyboard mic** in the app and the Live Activity stop
  control on a physical device. The user reported a Live Activity stopping problem
  in build 29; do not treat the rollback or unit tests as physical confirmation.
- [ ] Record the required demonstration using the exact submission build. Include
  the Home Screen, Notes in the foreground, clip recording, inserted text and
  ending the microphone session. Record device model, OS, app version and build.
  Add a verified attachment or accessible link, then replace the pending paragraph
  in the submission text. No demonstration file has been supplied for this draft.
- [ ] Repeat the flow on iPad, the device family involved in the previous review.
- [ ] Verify current welcome credit and review access on the deployed backend.
  Do not promise a grant value or purchase-free testing based on source defaults.
- [ ] Confirm the consumable products, their review screenshots and their
  association with the app submission in App Store Connect. Verify sandbox
  purchase, delivery and account-specific reconciliation separately.
- [ ] Confirm the company privacy and support pages are deployed and accessible
  before saving their URLs in App Store Connect.

Preparing metadata and attachments does not constitute App Review submission.
