import Testing
import UIKit

// This bundle compiles the production controller and shared stores directly.
// It exercises UIKit lifecycle and actual controls, without substituting a
// separate state-machine implementation for the code that crashed on device.
@Suite(.serialized)
@MainActor
struct KeyboardLifecycleTests {
    @Test func embeddedKeyboardDeclaresItsActualCapabilities() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let keyboard = try #require(Bundle(url: plugins.appendingPathComponent("VoiceTypeKeyboard.appex")))
        let extensionInfo = try #require(keyboard.infoDictionary?["NSExtension"] as? [String: Any])
        let attributes = try #require(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        #expect(extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.keyboard-service")
        #expect(extensionInfo["NSExtensionPrincipalClass"] as? String == "VoiceTypeKeyboard.KeyboardViewController")
        #expect(attributes["IsASCIICapable"] as? Bool == false)
        #expect(attributes["RequestsOpenAccess"] as? Bool == true)
    }

    @Test func actualControllerLoadsWithoutAHostDocument() {
        withCleanStores {
            let controller = KeyboardViewController()
            controller.loadViewIfNeeded()
            #expect(controller.isViewLoaded)
            #expect(controller.view.window == nil)
        }
    }

    @Test func keyboardLayoutKeepsTextControlsUsableAtCompactAndWideWidths() throws {
        try withCleanStores {
            // Still images must capture the final measured state, not the first
            // frame of a UIKit transition whose bars are entering the hierarchy.
            let animationsWereEnabled = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceTypeUIReview", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for width in [320, 390, 768] {
                for (styleName, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                    for (stateName, mode) in [("off", RecordingBridgeMode.standard), ("ready", .keyboardReady), ("recording", .keyboardRecording), ("transcribing", .transcribing), ("access", .keyboardReady)] {
                        setBridge(mode)
                        let controller = FixtureKeyboardController()
                        controller.fullAccess = stateName != "access"
                        controller.proxy.testDocumentIdentifier = UUID()
                        controller.proxy.testKeyboardAppearance = style == .dark ? .dark : .light
                        try withVisibleController(controller) {
                            if stateName == "access" {
                                try control("keyboard.primaryAction", in: controller).sendActions(for: .touchUpInside)
                            }
                            if stateName == "recording" {
                                // Known synthetic meter samples for visual QA;
                                // production obtains these from AVAudioRecorder.
                                let base = Date().addingTimeInterval(-0.3)
                                for (index, level) in [0.12, 0.2, 0.38, 0.75, 0.95, 0.72, 0.44, 0.6, 0.35, 0.18].enumerated() {
                                    setBridge(.keyboardRecording, audioLevel: level,
                                              updatedAt: base.addingTimeInterval(Double(index) * 0.025))
                                    controller.textDidChange(nil)
                                }
                            }
                            let fittingSize = controller.view.systemLayoutSizeFitting(
                                CGSize(width: CGFloat(width), height: 0),
                                withHorizontalFittingPriority: .required,
                                verticalFittingPriority: .fittingSizeLevel)
                            controller.view.window?.frame.size = fittingSize
                            controller.view.superview?.frame.size = fittingSize
                            controller.view.frame = CGRect(origin: .zero, size: fittingSize)
                            controller.view.setNeedsLayout()
                            controller.view.layoutIfNeeded()
                            if stateName == "recording" {
                                for index in 0..<10 {
                                    let bar = try #require(descendant("keyboard.audioLevel.\(index)", in: controller.view))
                                    #expect(abs(bar.bounds.width - 3.5) <= 1 / bar.traitCollection.displayScale)
                                    #expect(bar.bounds.height > 3.5)
                                }
                            }
                            for identifier in ["keyboard.return", "keyboard.delete"] {
                                let key = try control(identifier, in: controller)
                                #expect(key.bounds.width >= 44 && key.bounds.height >= 44)
                                let frame = key.convert(key.bounds, to: controller.view)
                                #expect(controller.view.bounds.contains(frame))
                            }
                            let action = try control("keyboard.primaryAction", in: controller)
                            let bottomKey = try control("keyboard.return", in: controller)
                            let actionFrame = action.convert(action.bounds, to: controller.view)
                            let bottomFrame = bottomKey.convert(bottomKey.bounds, to: controller.view)
                            #expect(actionFrame.maxY < bottomFrame.minY)
                            if stateName == "access" {
                                let helper = try #require(descendant("keyboard.helper", in: controller.view))
                                let helperFrame = helper.convert(helper.bounds, to: controller.view)
                                #expect(actionFrame.maxY < helperFrame.minY)
                                #expect(helperFrame.maxY < bottomFrame.minY)
                            }
                            let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
                            let rendered = renderer.image { context in
                                // The native keyboard material is transparent in
                                // a test host. Render on a neutral host surface;
                                // the physical host's blur remains a device check.
                                UIColor.secondarySystemBackground.resolvedColor(with: controller.traitCollection).setFill()
                                context.fill(controller.view.bounds)
                                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                            }
                            let data = try #require(rendered.pngData())
                            try data.write(to: directory.appendingPathComponent("keyboard-\(stateName)-\(styleName)-\(width).png"))
                        }
                    }
                }
            }
        }
    }

    @Test func teardownWithoutDisappearanceInvalidatesTheRunLoopTimer() async throws {
        try await withCleanStores {
            weak var releasedController: FixtureKeyboardController?
            let timer = try autoreleasepool {
                let controller = FixtureKeyboardController()
                releasedController = controller
                controller.loadViewIfNeeded()
                setVisible(true, controller: controller)
                return try #require(controller.refreshTimer)
            }
            defer { timer.invalidate() }
            // UIKit and an already-queued timer task may retain a controller
            // until the current run-loop turn finishes. Do not confuse that
            // bounded teardown work with a surviving run-loop timer.
            for _ in 0..<50 {
                if releasedController == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(releasedController == nil)
            #expect(!timer.isValid)
        }
    }

    @Test func waveformRespondsToMeasuredSoundAndSilenceWithoutReplayingSamples() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                #expect(controller.refreshTimer?.timeInterval == 0.25)
                let action = try control("keyboard.primaryAction", in: controller)
                setBridge(.keyboardRecording, audioLevel: 0.2)
                controller.textDidChange(nil)
                controller.view.layoutIfNeeded()
                let wave = try #require(descendant("keyboard.audioWaveform", in: controller.view))
                let bars = try (0..<10).map { try #require(descendant("keyboard.audioLevel.\($0)", in: wave)) }
                let quiet = bars.map(\.bounds.height)
                #expect(quiet.last! > 3.5)
                #expect(controller.refreshTimer?.timeInterval == 0.05)
                for _ in 0..<3 { controller.textDidChange(nil) }
                #expect(bars.map(\.bounds.height) == quiet)

                setBridge(.keyboardRecording, audioLevel: 0.9)
                controller.textDidChange(nil)
                #expect(bars.last!.bounds.height > quiet.last!)
                #expect(bars[8].bounds.height == quiet.last!)
                #expect(action.accessibilityLabel == "Tap to finish recording")
                #expect(action === (try control("keyboard.primaryAction", in: controller)))

                setBridge(.keyboardRecording, audioLevel: 0)
                controller.textDidChange(nil)
                #expect(bars.allSatisfy { abs($0.bounds.height - 3.5) <= 1 / $0.traitCollection.displayScale })
                setBridge(.keyboardRecording, audioLevel: 1)
                controller.textDidChange(nil)
                action.sendActions(for: .touchUpInside)
                #expect(RecordingBridgeStore.latestCommand?.action == .stopClip)
                #expect(action.accessibilityLabel == "Transcribing")
                #expect(bars.allSatisfy { abs($0.bounds.height - 3.5) <= 1 / $0.traitCollection.displayScale })
                #expect(controller.refreshTimer?.timeInterval == 0.25)
            }
        }
    }

    @Test func waveformClearsWhenSamplesStallAccessIsRevokedOrKeyboardLeaves() throws {
        try withCleanStores {
            setBridge(.keyboardRecording, audioLevel: 1)
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                controller.view.layoutIfNeeded()
                let bar = try #require(descendant("keyboard.audioLevel.9", in: controller.view))
                #expect(bar.bounds.height > 3.5)
                setBridge(.keyboardRecording, audioLevel: 1, updatedAt: Date().addingTimeInterval(-1))
                controller.textDidChange(nil)
                #expect(abs(bar.bounds.height - 3.5) <= 1 / bar.traitCollection.displayScale)
                setBridge(.keyboardRecording, audioLevel: 1)
                controller.textDidChange(nil)
                #expect(bar.bounds.height > 3.5)
                controller.fullAccess = false
                controller.textDidChange(nil)
                #expect(abs(bar.bounds.height - 3.5) <= 1 / bar.traitCollection.displayScale)
                #expect(controller.refreshTimer?.timeInterval == 0.25)
                controller.fullAccess = true
                controller.textDidChange(nil)
                controller.view.layoutIfNeeded()
                #expect(bar.bounds.height > 3.5)
                setVisible(false, controller: controller)
                #expect(abs(bar.bounds.height - 3.5) <= 1 / bar.traitCollection.displayScale)
                #expect(controller.refreshTimer == nil)
            }
        }
    }

    @Test func nullableObjectiveCIdentityCrossesSwiftBoundarySafely() {
        let controller = FixtureKeyboardController()
        #expect(VTKeyboardDocumentIdentifier(controller) == nil)
        let identifier = UUID()
        controller.proxy.testDocumentIdentifier = identifier
        #expect(VTKeyboardDocumentIdentifier(controller) as UUID? == identifier)
        controller.proxy.testDocumentIdentifier = nil
        #expect(VTKeyboardDocumentIdentifier(controller) == nil)
    }

    @Test func nilIdentityDuringLoadAppearanceAndTextChangesCannotInsertOrRecord() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.loadViewIfNeeded()
            #expect(controller.isViewLoaded)
            try withVisibleController(controller) {
                controller.textDidChange(nil)
                let action = try control("keyboard.primaryAction", in: controller)
                #expect(!action.isEnabled)
                action.sendActions(for: .touchUpInside)
                try control("keyboard.return", in: controller).sendActions(for: .touchUpInside)
                try control("keyboard.delete", in: controller).sendActions(for: .touchUpInside)
                #expect(RecordingBridgeStore.latestCommand == nil)
                #expect(controller.proxy.insertedTexts.isEmpty)
                #expect(controller.proxy.deleteCount == 0)
            }
        }
    }

    @Test func recordingInAVisibleDocumentInsertsExactlyOnce() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                try startAndStopClip(controller)
                let snapshot = completeTranscript()
                controller.textDidChange(nil)
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts == [snapshot.text])
                #expect(!KeyboardAutoInsertStore.shouldInsert(snapshot))
            }
        }
    }

    @Test func recoveredHistoryCannotEnterANewlyArmedKeyboardRecording() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                let action = try control("keyboard.primaryAction", in: controller)
                action.sendActions(for: .touchUpInside)
                // A retry can finish after the keyboard arms but before the
                // containing app receives its start command.
                let recovered = TranscriptSnapshot(id: UUID().uuidString, text: "Older recovered clip", createdAt: Date(), chargeText: nil)
                SharedTranscriptStore.appendHistory(recovered)
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts.isEmpty)
                #expect(SharedTranscriptStore.latest.id.isEmpty)
                #expect(SharedTranscriptStore.history.map(\.id) == [recovered.id])
                setBridge(.keyboardRecording)
                controller.textDidChange(nil)
                action.sendActions(for: .touchUpInside)
                let current = completeTranscript()
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts == [current.text])
                #expect(SharedTranscriptStore.history.map(\.id) == [current.id, recovered.id])
            }
        }
    }

    @Test func disposableMeterRejectsOtherSessionsAndExpiredSamples() {
        withCleanStores {
            let now = Date()
            RecordingAudioLevelStore.publish(sessionID: "current", level: 1.5, at: now)
            #expect(RecordingAudioLevelStore.latest(for: "current", at: now)?.level == 1)
            #expect(RecordingAudioLevelStore.latest(for: "previous", at: now) == nil)
            #expect(RecordingAudioLevelStore.latest(for: "current", at: now.addingTimeInterval(0.5)) == nil)
            #expect(RecordingAudioLevelStore.latest(for: "current", at: now.addingTimeInterval(-0.2)) == nil)
            RecordingAudioLevelStore.publish(sessionID: "current", level: .nan, at: now)
            #expect(RecordingAudioLevelStore.latest(for: "current", at: now)?.level == 0)
            RecordingAudioLevelStore.clear()
            #expect(RecordingAudioLevelStore.latest(for: "current", at: now) == nil)
        }
    }

    @Test func anAppearanceCallbackWithoutAWindowCannotArmRecording() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            controller.loadViewIfNeeded()
            setVisible(true, controller: controller)
            defer { setVisible(false, controller: controller) }
            let action = try control("keyboard.primaryAction", in: controller)
            #expect(controller.view.window == nil)
            #expect(!action.isEnabled)
            action.sendActions(for: .touchUpInside)
            #expect(RecordingBridgeStore.latestCommand == nil)
        }
    }

    @Test func revokingFullAccessDisarmsThePendingTranscript() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                try startAndStopClip(controller)
                controller.fullAccess = false
                let snapshot = completeTranscript()
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts.isEmpty)
                #expect(!KeyboardAutoInsertStore.shouldInsert(snapshot))
                controller.fullAccess = true
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts.isEmpty)
            }
        }
    }

    @Test func missingIdentityAfterStopDisarmsInsertionEvenWhenTheSameFieldReturns() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            let identifier = UUID()
            controller.proxy.testDocumentIdentifier = identifier
            try withVisibleController(controller) {
                try startAndStopClip(controller)
                controller.proxy.testDocumentIdentifier = nil
                let snapshot = completeTranscript()
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts.isEmpty)
                #expect(!KeyboardAutoInsertStore.shouldInsert(snapshot))
                controller.proxy.testDocumentIdentifier = identifier
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts.isEmpty)
            }
        }
    }

    @Test func switchingDocumentsNeverInsertsThePreviousFieldsTranscript() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                try startAndStopClip(controller)
                controller.proxy.testDocumentIdentifier = UUID()
                _ = completeTranscript()
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts.isEmpty)
            }
        }
    }

    @Test func disappearingBeforeTheResultPreventsInsertionAndKeyActions() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                try startAndStopClip(controller)
                setVisible(false, controller: controller)
                _ = completeTranscript()
                controller.textDidChange(nil)
                try control("keyboard.return", in: controller).sendActions(for: .touchUpInside)
                try control("keyboard.delete", in: controller).sendActions(for: .touchUpInside)
                #expect(controller.proxy.insertedTexts.isEmpty)
                #expect(controller.proxy.deleteCount == 0)
                setVisible(true, controller: controller)
                controller.textDidChange(nil)
                #expect(controller.proxy.insertedTexts.isEmpty)
            }
        }
    }

    @Test func withoutFullAccessBasicKeysWorkAndMicrophoneShowsManualInstructions() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.fullAccess = false
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                let action = try control("keyboard.primaryAction", in: controller)
                #expect(action.isEnabled)
                #expect(action.accessibilityLabel == "Show Full Access instructions")
                action.sendActions(for: .touchUpInside)
                #expect(action.accessibilityHint?.contains("Settings → General → Keyboard") == true)
                #expect(RecordingBridgeStore.latestCommand == nil)
                try control("keyboard.return", in: controller).sendActions(for: .touchUpInside)
                try control("keyboard.delete", in: controller).sendActions(for: .touchUpInside)
                #expect(controller.proxy.insertedTexts == ["\n"])
                #expect(controller.proxy.deleteCount == 1)
            }
        }
    }

    @Test func microphoneOffOffersAnUnobstructedSystemAppLink() throws {
        try withCleanStores {
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                let action = try control("keyboard.primaryAction", in: controller)
                #expect(action.isHidden)
                #expect(!action.isEnabled)
                let link = try #require(descendant("keyboard.openApp", in: controller.view))
                #expect(!link.isHidden)
                let activationURL = try #require(controller.keyboardActivationURL)
                #expect(activationURL.scheme == "voicetype")
                #expect(activationURL.host == "keyboard")
                controller.view.layoutIfNeeded()
                let point = link.convert(CGPoint(x: link.bounds.midX, y: link.bounds.midY), to: controller.view)
                let hit = try #require(controller.view.hitTest(point, with: nil))
                #expect(hit === link || hit.isDescendant(of: link))
                #expect(!hit.isDescendant(of: action))
                action.sendActions(for: .touchUpInside)
                let notice = try #require(descendant("keyboard.helper", in: controller.view))
                #expect(notice.isHidden)
                #expect(RecordingBridgeStore.latestCommand == nil)
                setBridge(.keyboardReady)
                controller.textDidChange(nil)
                #expect(link.isHidden)
                #expect(!action.isHidden && action.isEnabled)
                #expect(controller.keyboardActivationURL == nil)
                #expect(!KeyboardMicActivationStore.shared.consume(activationURL))
            }
        }
    }

    @Test func appLaunchDisappearancePreservesTheLinkUntilItIsConsumed() throws {
        try withCleanStores {
            let controller = FixtureKeyboardController()
            controller.proxy.testDocumentIdentifier = UUID()
            controller.loadViewIfNeeded()
            #expect(controller.keyboardActivationURL == nil)
            try withVisibleController(controller) {
                let url = try #require(controller.keyboardActivationURL)
                setVisible(false, controller: controller)
                // A normal Link launch hides the keyboard before onOpenURL may
                // reach the containing app. The request must survive that gap.
                #expect(KeyboardMicActivationStore.shared.consume(url))
                #expect(!KeyboardMicActivationStore.shared.consume(url))
                setVisible(true, controller: controller)
                let replacement = try #require(controller.keyboardActivationURL)
                #expect(replacement != url)
                #expect(KeyboardMicActivationStore.shared.consume(replacement))
            }
        }
    }

    @Test func missingOrRevokedFullAccessCannotIssueAnActivationLink() throws {
        try withCleanStores {
            let controller = FixtureKeyboardController()
            controller.fullAccess = false
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                let link = try #require(descendant("keyboard.openApp", in: controller.view))
                #expect(link.isHidden)
                #expect(controller.keyboardActivationURL == nil)
                controller.fullAccess = true
                controller.textDidChange(nil)
                let url = try #require(controller.keyboardActivationURL)
                #expect(!link.isHidden)
                controller.fullAccess = false
                controller.textDidChange(nil)
                #expect(link.isHidden)
                #expect(controller.keyboardActivationURL == nil)
                #expect(!KeyboardMicActivationStore.shared.consume(url))
            }
        }
    }

    @Test func compactKeyboardWithOwnGlobeKeepsEveryTextKeyReachable() throws {
        try withCleanStores {
            setBridge(.keyboardReady)
            let controller = FixtureKeyboardController()
            controller.showGlobe = true
            controller.proxy.testDocumentIdentifier = UUID()
            try withVisibleController(controller) {
                controller.view.frame.size.width = 320
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                for identifier in ["keyboard.nextKeyboard", "keyboard.return", "keyboard.delete", "keyboard.primaryAction"] {
                    let key = try control(identifier, in: controller)
                    #expect(!key.isHidden)
                    #expect(key.bounds.width >= 44 && key.bounds.height >= 44)
                    #expect(controller.view.bounds.contains(key.convert(key.bounds, to: controller.view)))
                }
            }
        }
    }

    private func descendant(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        return view.subviews.lazy.compactMap { descendant(identifier, in: $0) }.first
    }

    private func startAndStopClip(_ controller: FixtureKeyboardController) throws {
        let action = try control("keyboard.primaryAction", in: controller)
        #expect(action.isEnabled)
        action.sendActions(for: .touchUpInside)
        #expect(RecordingBridgeStore.latestCommand?.action == .startClip)
        setBridge(.keyboardRecording)
        controller.textDidChange(nil)
        #expect(action.isEnabled)
        action.sendActions(for: .touchUpInside)
        #expect(RecordingBridgeStore.latestCommand?.action == .stopClip)
        setBridge(.transcribing)
        controller.textDidChange(nil)
    }

    private func setBridge(_ mode: RecordingBridgeMode, audioLevel: Double = 0, updatedAt: Date = Date()) {
        if mode == .keyboardRecording {
            RecordingAudioLevelStore.publish(sessionID: "keyboard-lifecycle-test", level: audioLevel, at: updatedAt)
        } else {
            RecordingAudioLevelStore.clear()
        }
        RecordingBridgeStore.state = RecordingBridgeState(
            sessionID: "keyboard-lifecycle-test", isRecording: mode == .keyboardRecording,
            startedAt: Date(), updatedAt: updatedAt, durationLimit: .fiveMinutes, mode: mode,
            audioLevel: audioLevel
        )
    }

    private func completeTranscript() -> TranscriptSnapshot {
        let snapshot = TranscriptSnapshot(id: UUID().uuidString, text: "Keyboard regression transcript", createdAt: Date(), chargeText: nil)
        SharedTranscriptStore.latest = snapshot
        setBridge(.keyboardReady)
        return snapshot
    }

    private func control(_ identifier: String, in controller: UIViewController) throws -> UIControl {
        func find(_ view: UIView) -> UIControl? {
            if view.accessibilityIdentifier == identifier { return view as? UIControl }
            return view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(controller.view), "Missing actual keyboard control: \(identifier)")
    }

    private func withVisibleController(_ controller: KeyboardViewController, body: () throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 160))
        let host = KeyboardTestHostController()
        window.rootViewController = host
        window.isHidden = false
        host.addChild(controller)
        controller.loadViewIfNeeded()
        host.view.addSubview(controller.view)
        controller.view.frame = host.view.bounds
        controller.didMove(toParent: host)
        setVisible(true, controller: controller)
        #expect(controller.view.window != nil)
        defer {
            setVisible(false, controller: controller)
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
        }
        try body()
    }

    private func setVisible(_ visible: Bool, controller: UIViewController) {
        controller.beginAppearanceTransition(visible, animated: false)
        controller.endAppearanceTransition()
    }

    private func withCleanStores(body: () throws -> Void) rethrows {
        RecordingAudioLevelStore.clear()
        defer { RecordingAudioLevelStore.clear() }
        let keys = ["latestTranscript", "transcriptHistory", "recordingBridgeState", "recordingBridgeCommand",
                    "keyboardAutoInsertBaselineTranscriptID", "keyboardAutoInsertLastInsertedTranscriptID"]
        let defaults = UserDefaults(suiteName: AppConstants.appGroup)!
        let previous = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.synchronize()
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.synchronize()
        }
        try body()
    }

    private func withCleanStores(body: () async throws -> Void) async rethrows {
        RecordingAudioLevelStore.clear()
        defer { RecordingAudioLevelStore.clear() }
        let keys = ["latestTranscript", "transcriptHistory", "recordingBridgeState", "recordingBridgeCommand",
                    "keyboardAutoInsertBaselineTranscriptID", "keyboardAutoInsertLastInsertedTranscriptID"]
        let defaults = UserDefaults(suiteName: AppConstants.appGroup)!
        let previous = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.synchronize()
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.synchronize()
        }
        try await body()
    }
}

@MainActor
private final class FixtureKeyboardController: KeyboardViewController {
    let proxy = KeyboardTestDocumentProxy()
    var fullAccess = true
    var showGlobe = false
    override var textDocumentProxy: any UITextDocumentProxy { proxy }
    override var hasFullAccess: Bool { fullAccess }
    override var needsInputModeSwitchKey: Bool { showGlobe }
}

@MainActor
private final class KeyboardTestHostController: UIViewController {
    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
}
