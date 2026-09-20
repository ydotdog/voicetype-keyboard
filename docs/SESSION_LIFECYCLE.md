# Microphone session behavior

The Home screen's **Session length** controls the background microphone window. It does not control the length of one transcription.

This follows the user's requested fixed-window behavior. Wispr Flow also exposes
separate [iOS session-disable settings and a per-dictation limit](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android).
That public description does not establish its exact internal timer/recovery implementation.
[Typeless describes ready/activation microphone states](https://www.typeless.com/help/release-notes/ios/when-does-app-switching-happen)
and says its microphone is off while idle. VoiceType's current implementation
continuously captures temporary local audio while its explicitly enabled session
is active, so it must not claim identical idle-microphone behavior to Typeless.

- **5 min**: the window ends 300 seconds after turning on the keyboard microphone.
- **12 hr**: the window ends 43,200 seconds after turning it on.
- **Forever**: there is no automatic session deadline. The user can turn the microphone off; audio interruptions and unavailable input routes can also end it.
- Starting, stopping, transcribing, and repeating individual keyboard clips never reset the session start.
- Every individual keyboard clip has a separate 10-minute limit. Build 21 removes the standalone in-app recording entry; the internal standard-capture path retained for lifecycle/recovery tests also has its separate 10-minute limit.

## Opening the microphone from the keyboard — build 24

When the microphone is off, its outlined icon is a native Link into VoiceType.
That explicit keyboard action requests automatic background microphone activation
once the app is active and signed in. The only first-use microphone confirmation
is the system permission prompt; granting it continues activation. The user then
manually returns to the original app. Opening VoiceType normally does not activate
the microphone.

The default is **5 min**. Each new session reads the latest saved **5 min**, **12 hr**
or **Forever** selection, including after a permission prompt. Repeated activation
does not reset an existing window. If an old window has already expired, a fresh
explicit keyboard activation closes it and starts a new window with the saved
selection; a timer or ordinary foreground event cannot revive it.

Activation reaches **keyboard ready**. It does not begin a transcription clip or
upload the temporary idle audio. The user starts each clip from the keyboard.
The keyboard Link carries a short-lived, single-use request in the shared container;
generic, forged, expired and replayed links cannot enable the microphone. A valid
request can wait briefly for foregrounding or sign-in, and permission denial is
shown without repeatedly prompting on later foreground events.

## Recording feedback

During a keyboard clip, a dedicated 0.05-second timer publishes measured
`AVAudioRecorder` average power, normalized from -60...0 dBFS into 0...1. The
small disposable signal is atomically replaced in the App Group cache; it contains
only a session ID, level and timestamp. No raw audio is shared with the keyboard.
The maintenance timer stays at 0.25 seconds and the durable bridge heartbeat and
Live Activity level updates stay at most once per second, with immediate mode changes.

The visible recording keyboard reads the signal every 0.05 seconds, consumes each
timestamp once, and interpolates measured levels over 0.06 seconds. Its ten bars
represent roughly half a second of recent sound. Full keyboard state refresh stays
at 0.25 seconds. Silence clears the history. A wrong session, a sample older than
0.4 seconds, finishing a clip, loss of Full Access and disappearance reset the
waveform. Reduce Motion disables interpolation. Recording and app-opening buttons
show a microphone icon, and the recording action shows the waveform; accessible
labels still explain each action.

The active audio session explicitly permits haptics and system sounds. Buttons
prepare their haptic generator and emit one feedback event per press. Physical
haptic strength, microphone response and audio-route behavior require an iPhone.

## Failed recordings and History

Every unfinished or failed transcription has its own account-bound local audio
and metadata, keyed by the original request ID. Existing single-recording storage
migrates without changing that ID or the captured segment's offset. New recordings
can start while older failures remain in History, and a new success removes only
its own checkpoint. A failed live upload returns the still-valid microphone session
to ready; it does not restart or extend the selected session window.

History offers Retry and Delete per failed recording. One History retry runs at a
time, independently of the live recording task. Retry success is saved only to
History and never to the keyboard's latest-result or auto-insert channel. It cannot
insert an older clip into a newly armed input field. The original request ID is
reused so a lost response can be recovered without duplicate charging.

Same-account authentication expiry hides and preserves pending recordings for
reauthentication. Explicit sign-out, deletion or switching accounts removes the
appropriate audio. Late results are ignored after cancellation or an account change.
Audio must have a durable checkpoint before upload; if storage prevents saving,
VoiceType keeps the source while the app remains open and reports the storage error.

## Changing the setting

Changes apply relative to the original session start. For example, changing from 5 minutes to 12 hours at minute 4 changes the deadline to 12 hours after the original start. It does not add a new 12-hour window.

Shortening to a duration that has already elapsed closes capture immediately. An extension received after the old deadline cannot revive the old session, including when the preference callback runs before a delayed timer callback. The saved setting applies to the next session once closure has begun.

If the deadline arrives during a spoken clip, capture stops and the captured clip is transcribed. If an upload is already running, the microphone stops and that upload continues. The keyboard cannot begin a new clip after expiry. Failed uploads retain an account-bound recording for explicit retry.

## Timing, background work, and recovery

`RecordingSessionPolicy` uses a monotonic `ContinuousClock` sample for elapsed time; changing the device's date or time does not alter the window. The start date remains available for display. The same deadline policy runs before preference publication, recorder recovery, foreground maintenance, and keyboard commands.

`AVAudioRecorder.record(forDuration:)` also enforces finite session and clip limits at the recorder level. Changes rearm the recorder only when its native stop deadline changes. An unchanged deadline keeps capture continuous; a changed deadline pauses and resumes its existing file under a background task. This must be checked on physical devices for continuity and Bluetooth behavior. A successful timed stop preserves the known file endpoint because `currentTime` can reset after stopping.

Maintenance and the clip-only meter use separate timers on the main run loop's common modes. Timer callbacks never wait for transcription uploads, and queued callbacks from an earlier session are ignored. Idle recorder files rotate after 60 seconds when maintenance executes. This bounds normal idle storage use; prolonged OS scheduling stalls and abnormal termination still require device-level observation.

Calls, loss of the current microphone route, and audio-service resets end the active microphone window while preserving a captured clip or current upload where available. Recovery cannot silently restart a closed session.

## Shared status

The keyboard receives a heartbeat and a deadline computed from monotonic remaining time. Expired capture is hidden even if its heartbeat is fresh. Upload status can remain visible past capture expiry. Heartbeats older than 10 seconds are treated as inactive, and readers do not delete a newer state another process may have written.

Live Activities become stale after 30 seconds without updates or at the capture deadline, whichever is sooner. Upload status uses the heartbeat limit so a valid upload can finish after the microphone stops. A stale widget asks the user to open VoiceType instead of claiming the microphone remains active.

## Verification scope

Executable policy tests cover finite and unlimited windows, repeated clips, shortening and extension, late preference callbacks, every expiry phase, independent clip limits, simulated suspension, wall-clock changes, native recorder budgets, and bridge/Live Activity expiry. Separate executable tests cover saved-recording ownership and weak observer lifetimes/concurrent lookup.

These tests do not establish physical microphone continuity, long-duration battery consumption, actual 12-hour operation, Bluetooth route behavior, or successful recording through phone-call interruptions. Release validation must exercise those relevant device cases, including a real 5-minute session and repeated clips across background/foreground transitions.
