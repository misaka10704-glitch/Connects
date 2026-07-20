import UIKit

#if DEBUG
/// Developer-only scroll stress: multi-turn fixture + automated up-scroll through Q&A pairs.
/// Launch args: `-ScrollStressFixture`, `-ScrollStressTest`, optional `-ScrollStressSlow` (iPad-like pacing).
/// Ultra: `-ScrollStressUltraSlow` — Air 1–class pacing with mid-scroll sampling (implies slow).
/// Mixed: `-ScrollStressMixedPacing` — alternate fast fling + ultra-slow steps each run.
/// Diverse: `-ScrollStressDiverse` — mixed chat + first-open + matrix in one launch.
/// First-open QA edge: `-ScrollStressFirstOpen` — cold open + micro scroll at user-bubble edges.
/// Bubble wiggle: `-ScrollStressBubbleWiggle` — oscillate near assistant bubble after first QA edge.
/// Relaunch QA jitter: `-ScrollStressRelaunchQA` — multi-conversation cold opens + first QA-edge micro-drift.
/// Ultra switch: `-ScrollStressUltraSwitch` — cold open + mid-scroll width/study toggles (use with UltraSlow).
/// Study bug path: `-ScrollStressStudyFixture -ScrollStressStudy` (narrow panel + reasoning + 卷积公式).
/// Matrix path: `-ScrollStressStudyFixture -ScrollStressMatrix -ScrollStressSlow` (portrait/landscape chat + PDF).
enum ScrollStressHarness {
    private static let logTag = "[ConnectsScrollStress]"
    private static var didSchedule = false
    private static let turnCount = 20
    private static let studyTurnCount = 10
    private static let fullChatTableWidth: CGFloat = 1024
    private static let portraitChatTableWidth: CGFloat = 768
    private static let studyPanelTableWidth: CGFloat = 408
    private static var ultraSlowMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressUltraSlow")
    }
    private static var mathHeavyMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressMathHeavy")
    }
    private static var studyMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressStudy")
    }
    private static var slowMode: Bool {
        ultraSlowMode || ProcessInfo.processInfo.arguments.contains("-ScrollStressSlow")
    }
    private static var rotationMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressRotate")
    }
    private static var matrixMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressMatrix")
    }
    private static var ultraSwitchMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressUltraSwitch")
    }
    private static var firstOpenMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressFirstOpen")
    }
    private static var firstBubbleMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressFirstBubble")
    }
    private static var bubbleWiggleMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressBubbleWiggle")
    }
    private static var relaunchQAMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressRelaunchQA")
    }
    private static var mixedPacingMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressMixedPacing")
            || ProcessInfo.processInfo.arguments.contains("-ScrollStressDiverse")
    }
    private static var diverseMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressDiverse")
    }

    private enum PacingProfile: String {
        case fast
        case slow
        case ultra
    }

    static func installFixtureIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("-ScrollStressStudyFixture")
            || (ProcessInfo.processInfo.arguments.contains("-ScrollStressFixture") && (studyMode || matrixMode || ultraSwitchMode || firstOpenMode || firstBubbleMode || bubbleWiggleMode || relaunchQAMode || diverseMode)) {
            installStudyFixture()
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("-ScrollStressFixture") else { return }
        let store = ConversationStore.shared
        store.updateCurrentQuietly { conversation in
            conversation.title = mathHeavyMode
                ? "公式压测 实数完备性 \(turnCount)轮"
                : "滚动测试 \(turnCount)轮"
            conversation.messages.removeAll()
            for turn in 1...turnCount {
                conversation.messages.append(ChatMessage(
                    role: .user,
                    content: mathHeavyMode
                        ? userQuestion(turn: turn)
                        : "问题 \(turn)：请推导方差公式、写出期望与方差的关系，并给出一个数值例子。"
                ))
                conversation.messages.append(ChatMessage(
                    role: .assistant,
                    content: mathHeavyMode ? mathHeavyAssistantBody(turn: turn) : assistantBody(turn: turn),
                    reasoningContent: turn.isMultiple(of: 2) ? "先展开期望，再用独立同分布假设，最后代入具体数字。" : "",
                    isStreaming: false
                ))
            }
        }
        log("installed \(turnCount)-turn fixture\(mathHeavyMode ? " (math-heavy completeness)" : "") (persisted)")
    }

    static func scheduleIfRequested(on chat: ChatViewController) {
        guard ProcessInfo.processInfo.arguments.contains("-ScrollStressTest")
            || ProcessInfo.processInfo.arguments.contains("-ScrollStressRotate")
            || ProcessInfo.processInfo.arguments.contains("-ScrollStressStudy")
            || matrixMode
            || ultraSwitchMode
            || firstOpenMode
            || firstBubbleMode
            || bubbleWiggleMode
            || relaunchQAMode
            || diverseMode else { return }
        guard !didSchedule else { return }
        didSchedule = true
        if diverseMode {
            log("scheduled diverse stress (fast+ultra mixed: chat → first-open → matrix)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                runDiverse(on: chat)
            }
            return
        }
        if relaunchQAMode {
            log("scheduled relaunch QA jitter stress (multi-conversation cold opens)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                runRelaunchQA(on: chat)
            }
            return
        }
        if bubbleWiggleMode {
            log("scheduled bubble-wiggle history scroll test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                runBubbleWiggle(on: chat)
            }
            return
        }
        if firstBubbleMode {
            log("scheduled first-bubble study-landscape anchor test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                runFirstBubble(on: chat)
            }
            return
        }
        if firstOpenMode {
            log("scheduled first-open QA-edge stress\(mixedPacingMode ? " (fast+ultra mixed)" : (ultraSlowMode ? " [ultra/Air1]" : ""))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                runFirstOpen(on: chat)
            }
            return
        }
        if ultraSwitchMode {
            log("scheduled ultra switch (cold open + mid-scroll toggles)\(ultraSlowMode ? " [ultra/Air1]" : "")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                runUltraSwitch(on: chat)
            }
            return
        }
        if matrixMode {
            log("scheduled orientation matrix\(mixedPacingMode ? " (fast+ultra mixed)" : (ultraSlowMode ? " [ultra/Air1]" : ""))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                runMatrix(on: chat)
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ScrollStressStudy") {
            log("scheduled study-panel stress (blank + narrow math scroll)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                runStudy(on: chat)
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ScrollStressRotate") {
            log("scheduled rotation stress on chat VC")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                runRotation(on: chat)
            }
            return
        }
        log("scheduled on chat VC\(mixedPacingMode ? " (fast+ultra mixed)" : (ultraSlowMode ? " (ultra/Air1 pacing)" : (slowMode ? " (slow/iPad pacing)" : "")))\(mathHeavyMode ? " (math-heavy)" : "")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            run(on: chat)
        }
    }

    private static func log(_ message: String) {
        let line = "\(logTag) \(message)\n"
        fputs(line, stderr)
        fflush(stderr)
    }

    // MARK: - Pacing profiles (fast fling + ultra-slow observation)

    private enum ScrollDistanceStyle {
        case chat
        case matrix
        case qaEdge
    }

    private static func profileForStep(_ step: Int) -> PacingProfile {
        if mixedPacingMode {
            return step.isMultiple(of: 2) ? .fast : .ultra
        }
        if ultraSlowMode { return .ultra }
        if slowMode { return .slow }
        return .fast
    }

    private static func scrollDistance(step: Int, profile: PacingProfile, style: ScrollDistanceStyle) -> CGFloat {
        switch style {
        case .chat, .matrix:
            switch profile {
            case .fast:
                return step.isMultiple(of: 3) ? 340 : (step.isMultiple(of: 2) ? 260 : 180)
            case .ultra:
                return step.isMultiple(of: 3) ? 200 : (step.isMultiple(of: 2) ? 140 : 90)
            case .slow:
                return step.isMultiple(of: 3) ? 200 : (step.isMultiple(of: 2) ? 140 : 90)
            }
        case .qaEdge:
            let fallback: CGFloat = step.isMultiple(of: 3) ? 72 : (step.isMultiple(of: 2) ? 48 : 36)
            switch profile {
            case .fast: return fallback * 2.2
            case .ultra: return fallback * 1.15
            case .slow: return fallback
            }
        }
    }

    private static func pacingSuffix(_ profile: PacingProfile? = nil) -> String {
        if mixedPacingMode { return " [mixed fast+ultra]" }
        if let profile = profile, profile == .fast { return " [fast]" }
        if ultraSlowMode { return " [ultra]" }
        if slowMode { return " [slow]" }
        return ""
    }

    // MARK: - Air 1–class pacing (ultra-slow exposes mid-scroll clip/shift/blank)

    private struct ScrollPacing {
        let scrollDuration: TimeInterval
        let settleMs: TimeInterval
        let midScrollFractions: [CGFloat]
        let postScrollSampleMs: [TimeInterval]
        let driftAllowance: CGFloat
        let stableMaxAttempts: Int
        let chromeShiftTolerance: CGFloat

        static func forProfile(_ profile: PacingProfile,
                               mathHeavy: Bool,
                               studyBlank: Bool = false) -> ScrollPacing {
            switch profile {
            case .fast:
                return ScrollPacing(
                    scrollDuration: studyBlank ? 0.14 : 0.11,
                    settleMs: studyBlank ? 0.48 : 0.42,
                    midScrollFractions: [],
                    postScrollSampleMs: [0.024, 0.072, 0.14, 0.24],
                    driftAllowance: mathHeavy ? (studyBlank ? 64 : 56) : (studyBlank ? 58 : 48),
                    stableMaxAttempts: 140,
                    chromeShiftTolerance: 10
                )
            case .ultra:
                if studyBlank {
                    return ScrollPacing(
                        scrollDuration: 6.4,
                        settleMs: 4.4,
                        midScrollFractions: [0.14, 0.3, 0.46, 0.62, 0.78, 0.9],
                        postScrollSampleMs: [0.05, 0.12, 0.25, 0.5, 1.0, 1.8, 2.8],
                        driftAllowance: 58,
                        stableMaxAttempts: 300,
                        chromeShiftTolerance: 12
                    )
                }
                return ScrollPacing(
                    scrollDuration: mathHeavy ? 5.8 : 5.8,
                    settleMs: 4.0,
                    midScrollFractions: [0.12, 0.28, 0.44, 0.58, 0.72, 0.86],
                    postScrollSampleMs: [0.04, 0.08, 0.16, 0.28, 0.45, 0.7, 1.1, 1.8, 2.6],
                    driftAllowance: mathHeavy ? 54 : 46,
                    stableMaxAttempts: 280,
                    chromeShiftTolerance: 12
                )
            case .slow:
                return ScrollPacing(
                    scrollDuration: studyBlank ? 1.6 : 1.85,
                    settleMs: studyBlank ? 1.0 : (mathHeavy ? 2.4 : 1.15),
                    midScrollFractions: [],
                    postScrollSampleMs: [0.048],
                    driftAllowance: mathHeavy ? 48 : 36,
                    stableMaxAttempts: 80,
                    chromeShiftTolerance: 8
                )
            }
        }

        static func chat(mathHeavy: Bool) -> ScrollPacing {
            if mixedPacingMode {
                return forProfile(.ultra, mathHeavy: mathHeavy)
            }
            if ultraSlowMode {
                return ScrollPacing(
                    scrollDuration: 5.8,
                    settleMs: 4.0,
                    midScrollFractions: [0.12, 0.28, 0.44, 0.58, 0.72, 0.86],
                    postScrollSampleMs: [0.04, 0.08, 0.16, 0.28, 0.45, 0.7, 1.1, 1.8, 2.6],
                    driftAllowance: mathHeavy ? 54 : 46,
                    stableMaxAttempts: 280,
                    chromeShiftTolerance: 12
                )
            }
            if slowMode {
                return ScrollPacing(
                    scrollDuration: 1.85,
                    settleMs: mathHeavy ? 2.4 : 1.15,
                    midScrollFractions: [],
                    postScrollSampleMs: [0.048],
                    driftAllowance: mathHeavy ? 48 : 36,
                    stableMaxAttempts: 80,
                    chromeShiftTolerance: 8
                )
            }
            return ScrollPacing(
                scrollDuration: 0.32,
                settleMs: mathHeavy ? 1.6 : 0.72,
                midScrollFractions: [],
                postScrollSampleMs: [],
                driftAllowance: mathHeavy ? 48 : 36,
                stableMaxAttempts: 80,
                chromeShiftTolerance: 8
            )
        }

        static func study() -> ScrollPacing {
            if mixedPacingMode {
                return forProfile(.ultra, mathHeavy: true, studyBlank: true)
            }
            if ultraSlowMode {
                return ScrollPacing(
                    scrollDuration: 6.2,
                    settleMs: 4.2,
                    midScrollFractions: [0.15, 0.32, 0.5, 0.68, 0.84],
                    postScrollSampleMs: [0.05, 0.12, 0.25, 0.5, 1.0, 1.8, 2.8],
                    driftAllowance: 56,
                    stableMaxAttempts: 300,
                    chromeShiftTolerance: 12
                )
            }
            return ScrollPacing(
                scrollDuration: slowMode ? 1.6 : 0.55,
                settleMs: slowMode ? 1.0 : 0.85,
                midScrollFractions: [],
                postScrollSampleMs: [],
                driftAllowance: 52,
                stableMaxAttempts: 120,
                chromeShiftTolerance: 8
            )
        }

        static func matrix(studyBlank: Bool) -> ScrollPacing {
            if mixedPacingMode {
                return forProfile(.ultra, mathHeavy: true, studyBlank: studyBlank)
            }
            let base = chat(mathHeavy: true)
            if ultraSlowMode {
                return ScrollPacing(
                    scrollDuration: studyBlank ? 6.4 : 5.8,
                    settleMs: studyBlank ? 4.4 : 4.0,
                    midScrollFractions: studyBlank
                        ? [0.14, 0.3, 0.46, 0.62, 0.78, 0.9]
                        : [0.12, 0.28, 0.44, 0.6, 0.76, 0.88],
                    postScrollSampleMs: base.postScrollSampleMs,
                    driftAllowance: studyBlank ? 58 : 46,
                    stableMaxAttempts: base.stableMaxAttempts,
                    chromeShiftTolerance: base.chromeShiftTolerance
                )
            }
            return ScrollPacing(
                scrollDuration: slowMode ? 1.6 : 0.45,
                settleMs: slowMode ? 1.0 : 0.72,
                midScrollFractions: [],
                postScrollSampleMs: [0.048],
                driftAllowance: studyBlank ? 52 : 40,
                stableMaxAttempts: 100,
                chromeShiftTolerance: 8
            )
        }
    }

    private static func scheduleMidScrollSamples(chat: ChatViewController,
                                                 pacing: ScrollPacing,
                                                 scrollDuration: TimeInterval,
                                                 step: Int,
                                                 labelPrefix: String,
                                                 studyBlank: Bool,
                                                 onClip: @escaping () -> Void,
                                                 onBlank: @escaping () -> Void,
                                                 onChromeLate: @escaping () -> Void,
                                                 onFlicker: @escaping () -> Void,
                                                 baseline: [Int: CGFloat]?) {
        guard !pacing.midScrollFractions.isEmpty else { return }
        _ = baseline
        for frac in pacing.midScrollFractions {
            let delay = scrollDuration * Double(frac) + 0.14
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let flicker = chat.debugVisibleActionChromeFlickerCount()
                if flicker > 0 {
                    onFlicker()
                    log("\(labelPrefix) flicker-mid step=\(step) frac=\(Int(frac * 100))% rows=\(flicker)")
                }
                if studyBlank {
                    let blank = chat.debugVisibleStudyBlankState()
                    // Mid-scroll: only hard-fail on unpainted bodies / gaps. Chrome reserve slack is expected.
                    if blank.unrenderedAssistants > 0 || blank.interRowGaps > 0
                        || (blank.inflatedRows > 0 && blank.maxRowSlackPt > 48) {
                        onBlank()
                        log("\(labelPrefix) blank-mid step=\(step) frac=\(Int(frac * 100))% inflated=\(blank.inflatedRows) unrendered=\(blank.unrenderedAssistants) gaps=\(blank.interRowGaps) maxSlack=\(Int(blank.maxRowSlackPt))pt")
                    }
                }
                let snap = chat.debugVisibleActionChromeSnapshot()
                if snap.missingButtons > 0 {
                    onChromeLate()
                    log("\(labelPrefix) chrome-mid step=\(step) frac=\(Int(frac * 100))% missing=\(snap.missingButtons)")
                }
            }
        }
    }

    private static func schedulePostScrollSamples(chat: ChatViewController,
                                                  pacing: ScrollPacing,
                                                  step: Int,
                                                  labelPrefix: String,
                                                  onChromeLate: @escaping () -> Void) {
        for ms in pacing.postScrollSampleMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + ms) {
                let snap = chat.debugVisibleActionChromeSnapshot()
                if snap.missingButtons > 0 {
                    onChromeLate()
                    log("\(labelPrefix) chrome-late step=\(step) t+\(Int(ms * 1000))ms missing=\(snap.missingButtons)")
                }
            }
        }
    }

    private static func run(on chat: ChatViewController) {
        chat.loadViewIfNeeded()
        chat.reloadChat()
        let warmupDelay: TimeInterval = mathHeavyMode ? 3.5 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + warmupDelay) {
            if mathHeavyMode,
               let messages = ConversationStore.shared.currentConversation?.messages {
                let assistants = messages.filter { $0.role == .assistant && !$0.isStreaming }
                let width = chat.debugLayoutContentWidth()
                log("prewarming \(assistants.count) math-heavy assistant layouts")
                AssistantMessageLayout.prewarmLayouts(
                    for: assistants,
                    targetWidth: width,
                    layoutLimit: assistants.count
                )
                chat.debugSeedCommittedHeightsFromLayoutCache()
            }
            runScrollSteps(on: chat)
        }
    }

    private static func runScrollSteps(on chat: ChatViewController,
                                       exitOnFinish: Bool = true,
                                       completion: ((Bool) -> Void)? = nil) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              messages.count >= turnCount * 2 - 2 else {
            log("FAIL missing fixture (need -ScrollStressFixture, \(turnCount) turns)")
            completion?(false)
            if exitOnFinish { exit(1) }
            return
        }
        log("begin \(messages.count) messages, \(turnCount) turns\(pacingSuffix())")
        var step = 0
        let totalSteps = mixedPacingMode ? 14 : (ultraSlowMode ? 12 : (slowMode ? 16 : 28))
        var jumpFailures = 0
        var renderFailures = 0
        var clipFailures = 0
        var chromeLateFailures = 0
        var chromeShiftFailures = 0
        var flickerFailures = 0

        func finish() {
            let pass = jumpFailures == 0 && renderFailures == 0 && clipFailures == 0
                && chromeLateFailures == 0 && chromeShiftFailures == 0 && flickerFailures == 0
            if pass {
                log("PASS completed \(totalSteps) scroll steps\(pacingSuffix())")
            } else {
                if jumpFailures > 0 {
                    log("FAIL \(jumpFailures) viewport jumps in \(totalSteps) steps")
                }
                if renderFailures > 0 {
                    log("FAIL \(renderFailures) render/chrome regressions in \(totalSteps) steps")
                }
                if clipFailures > 0 {
                    log("FAIL \(clipFailures) row-clip/chrome overlap in \(totalSteps) steps")
                }
                if chromeLateFailures > 0 {
                    log("FAIL \(chromeLateFailures) late action-chrome reveals in \(totalSteps) steps")
                }
                if chromeShiftFailures > 0 {
                    log("FAIL \(chromeShiftFailures) action-chrome position shifts in \(totalSteps) steps")
                }
                if flickerFailures > 0 {
                    log("FAIL \(flickerFailures) action-chrome flicker events in \(totalSteps) steps")
                }
            }
            fflush(stderr)
            completion?(pass)
            if exitOnFinish { exit(pass ? 0 : 1) }
        }

        func sampleChrome(step: Int, label: String, baseline: [Int: CGFloat]?, pacing: ScrollPacing) {
            let snap = chat.debugVisibleActionChromeSnapshot()
            if label.hasPrefix("t+") && label != "t+settle" {
                if snap.missingButtons > 0 {
                    chromeLateFailures += 1
                    log("chrome-late step=\(step) missing=\(snap.missingButtons) at \(label)")
                }
            }
            if let baseline = baseline, !snap.buttonViewportY.isEmpty {
                for (row, y0) in baseline {
                    guard let y1 = snap.buttonViewportY[row] else { continue }
                    if abs(y1 - y0) > pacing.chromeShiftTolerance {
                        chromeShiftFailures += 1
                        log("chrome-shift step=\(step) row=\(row) delta=\(Int(abs(y1 - y0)))pt \(label)")
                    }
                }
            }
        }

        func next() {
            guard step < totalSteps else {
                finish()
                return
            }
            let profile = profileForStep(step)
            let pacing = mixedPacingMode
                ? ScrollPacing.forProfile(profile, mathHeavy: mathHeavyMode)
                : ScrollPacing.chat(mathHeavy: mathHeavyMode)
            let settleMs = pacing.settleMs
            let driftAllowance = pacing.driftAllowance
            if mixedPacingMode || ultraSlowMode {
                let distancePreview = scrollDistance(step: step, profile: profile, style: .chat)
                log("chat-\(profile.rawValue) step=\(step + 1)/\(totalSteps) dist=\(Int(distancePreview)) dur=\(String(format: "%.2f", pacing.scrollDuration))s")
            }
            let anchor = chat.debugScrollAnchorSnapshot()
            _ = chat.debugContentOffsetY()
            let distance = scrollDistance(step: step, profile: profile, style: .chat)
            let scrollDuration = pacing.scrollDuration
            let simulate: (@escaping () -> Void) -> Void = { done in
                chat.debugSimulateSlowScrollUp(distance: distance, duration: scrollDuration, completion: done)
            }
            let baselineBefore = chat.debugVisibleActionChromeSnapshot().buttonViewportY
            scheduleMidScrollSamples(
                chat: chat,
                pacing: pacing,
                scrollDuration: scrollDuration,
                step: step,
                labelPrefix: "chat",
                studyBlank: false,
                onClip: { clipFailures += 1 },
                onBlank: {},
                onChromeLate: { chromeLateFailures += 1 },
                onFlicker: { flickerFailures += 1 },
                baseline: baselineBefore
            )
            simulate {
                let baseline = chat.debugVisibleActionChromeSnapshot().buttonViewportY
                schedulePostScrollSamples(
                    chat: chat,
                    pacing: pacing,
                    step: step,
                    labelPrefix: "chat",
                    onChromeLate: { chromeLateFailures += 1 }
                )
                func checkAfterSettle() {
                    if let anchor = anchor {
                        let expectedY = anchor.viewportY + distance
                        if let drift = chat.debugViewportDrift(row: anchor.row, expectedY: expectedY, maxAllowed: driftAllowance) {
                            jumpFailures += 1
                            log("jump step=\(step) row=\(anchor.row) drift=\(Int(drift))pt (post-render)")
                        }
                    }
                    let qa = chat.debugVisibleCrossQAState()
                    if qa.unrenderedAssistants > 0 || qa.missingActionButtons > 0 {
                        renderFailures += 1
                        log("render step=\(step) unrendered=\(qa.unrenderedAssistants) missingActions=\(qa.missingActionButtons)")
                    }
                    let clipped = chat.debugVisibleRowClipCount()
                    if clipped > 0 {
                        clipFailures += 1
                        log("clip step=\(step) rows=\(clipped)")
                    }
                    if chat.debugVisibleActionChromeFlickerCount() > 0 {
                        flickerFailures += 1
                        log("flicker step=\(step) t+settle")
                    }
                    sampleChrome(step: step, label: "t+settle", baseline: baseline, pacing: pacing)
                    step += 1
                    next()
                }
                func checkMidScroll() {
                    let sampleEarly = profile == .fast || pacing.midScrollFractions.isEmpty
                    if sampleEarly {
                        let clipped = chat.debugVisibleRowClipCount()
                        if clipped > 0 {
                            clipFailures += 1
                            log("clip-early step=\(step) profile=\(profile.rawValue) rows=\(clipped) at t+0")
                        }
                    }
                    sampleChrome(step: step, label: "t+0", baseline: nil, pacing: pacing)
                    if sampleEarly {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.048) {
                            sampleChrome(step: step, label: "t+48ms", baseline: nil, pacing: pacing)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + settleMs) {
                        chat.debugWaitForReadingHistoryStable(maxAttempts: pacing.stableMaxAttempts) {
                            checkAfterSettle()
                        }
                    }
                }
                checkMidScroll()
            }
        }
        next()
    }

    // MARK: - Study panel (blank gap + narrow multi-formula scroll)

    private static func installStudyFixture() {
        let store = ConversationStore.shared
        store.updateCurrentQuietly { conversation in
            conversation.title = "Study压测 冲激/卷积 \(studyTurnCount)轮"
            conversation.messages.removeAll()
            for turn in 1...studyTurnCount {
                conversation.messages.append(ChatMessage(
                    role: .user,
                    content: studyUserQuestion(turn: turn)
                ))
                conversation.messages.append(ChatMessage(
                    role: .assistant,
                    content: studyAssistantBody(turn: turn),
                    reasoningContent: studyReasoning(turn: turn),
                    isStreaming: false
                ))
            }
        }
        log("installed \(studyTurnCount)-turn study fixture (impulse + convolution)")
    }

    private static func runStudy(on chat: ChatViewController) {
        chat.loadViewIfNeeded()
        chat.reloadChat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                guard let messages = ConversationStore.shared.currentConversation?.messages,
                      messages.count >= studyTurnCount * 2 else {
                    log("FAIL study: missing fixture (need -ScrollStressStudyFixture)")
                    return
                }
                // Warm path: full-width chat then open PDF side panel (stale bucket → blank rows).
                chat.debugPersistHeightCacheForCurrentWidth()
                log("phase enter study panel warm w=\(Int(studyPanelTableWidth))")
                chat.debugPinToBottom {
                    chat.debugEnterStudyPanel(tableWidth: studyPanelTableWidth) {
                        chat.debugWaitForStudyRelayoutStable {
                            runStudyBlankCheck(on: chat)
                        }
                    }
                }
            }
        }
    }

    private static func runStudyBlankCheck(on chat: ChatViewController) {
        let blank = chat.debugVisibleStudyBlankState()
        var blankFailures = 0
        if blank.unrenderedAssistants > 0 {
            blankFailures += 1
            log("study-blank unrendered=\(blank.unrenderedAssistants)")
        }
        if blank.inflatedRows > 0 {
            blankFailures += 1
            log("study-blank inflatedRows=\(blank.inflatedRows) maxSlack=\(Int(blank.maxRowSlackPt))pt")
        }
        if blank.interRowGaps > 0 {
            blankFailures += 1
            log("study-blank interRowGaps=\(blank.interRowGaps) maxGap=\(Int(blank.maxInterRowGapPt))pt")
        }
        let qa = chat.debugVisibleCrossQAState()
        if qa.unrenderedAssistants > 0 {
            blankFailures += 1
            log("study-blank native-missing=\(qa.unrenderedAssistants)")
        }
        let clipped = chat.debugVisibleRowClipCount()
        if clipped > 0 {
            blankFailures += 1
            log("study-blank clip=\(clipped)")
        }
        if qa.missingActionButtons > 0 {
            blankFailures += 1
            log("study-blank missingActions=\(qa.missingActionButtons)")
        }
        if blankFailures > 0 {
            log("FAIL study blank check (\(blankFailures) issues)")
        } else {
            log("PASS study blank check (maxSlack=\(Int(blank.maxRowSlackPt))pt)")
        }
        runStudyScrollSteps(on: chat, priorBlankFailures: blankFailures)
    }

    private static func runStudyScrollSteps(on chat: ChatViewController, priorBlankFailures: Int) {
        guard let messages = ConversationStore.shared.currentConversation?.messages else {
            log("FAIL study scroll: no messages")
            return
        }
        let targetRow = max(0, messages.count - studyTurnCount * 2)
        log("phase C study scroll from tail to row \(targetRow) (\(studyTurnCount) formula turns)")
        chat.debugScrollToRow(messages.count - 1) {
            var step = 0
            let pacing = ScrollPacing.study()
            let totalSteps = ultraSlowMode ? 10 : 8
            var jumpFailures = 0
            var renderFailures = 0
            var clipFailures = 0
            var blankFailures = priorBlankFailures
            var chromeLateFailures = 0
            var chromeShiftFailures = 0
            var flickerFailures = 0
            let settleMs = pacing.settleMs
            let driftAllowance = pacing.driftAllowance

            func finish() {
                chat.debugClearLayoutWidthOverride()
                chat.setStudyChrome(.none)
                if blankFailures == 0, jumpFailures == 0, renderFailures == 0, clipFailures == 0,
                   chromeLateFailures == 0, chromeShiftFailures == 0, flickerFailures == 0 {
                    log("PASS study stress blank+scroll (\(totalSteps) steps)\(ultraSlowMode ? " [ultra]" : "")")
                } else {
                    if blankFailures > 0 { log("FAIL study blank (\(blankFailures) phases)") }
                    if jumpFailures > 0 { log("FAIL study scroll jumps \(jumpFailures)/\(totalSteps)") }
                    if renderFailures > 0 { log("FAIL study render \(renderFailures)/\(totalSteps)") }
                    if clipFailures > 0 { log("FAIL study clip \(clipFailures)/\(totalSteps)") }
                    if chromeLateFailures > 0 { log("FAIL study chrome-late \(chromeLateFailures)") }
                    if chromeShiftFailures > 0 { log("FAIL study chrome-shift \(chromeShiftFailures)") }
                    if flickerFailures > 0 { log("FAIL study flicker \(flickerFailures)") }
                }
                fflush(stderr)
                exit(blankFailures == 0 && jumpFailures == 0 && renderFailures == 0 && clipFailures == 0
                    && chromeLateFailures == 0 && chromeShiftFailures == 0 && flickerFailures == 0 ? 0 : 1)
            }

            func next() {
                guard step < totalSteps else {
                    finish()
                    return
                }
                log("study-scroll step \(step + 1)/\(totalSteps)…")
                fflush(stderr)
                let anchor = chat.debugScrollAnchorSnapshot()
                let distance: CGFloat = step.isMultiple(of: 3) ? 220 : (step.isMultiple(of: 2) ? 160 : 110)
                let scrollDuration = pacing.scrollDuration
                let baselineBefore = chat.debugVisibleActionChromeSnapshot().buttonViewportY
                scheduleMidScrollSamples(
                    chat: chat,
                    pacing: pacing,
                    scrollDuration: scrollDuration,
                    step: step,
                    labelPrefix: "study",
                    studyBlank: true,
                    onClip: { clipFailures += 1 },
                    onBlank: { blankFailures += 1 },
                    onChromeLate: { chromeLateFailures += 1 },
                    onFlicker: { flickerFailures += 1 },
                    baseline: baselineBefore
                )
                schedulePostScrollSamples(
                    chat: chat,
                    pacing: pacing,
                    step: step,
                    labelPrefix: "study",
                    onChromeLate: { chromeLateFailures += 1 }
                )
                chat.debugSimulateSlowScrollUp(distance: distance, duration: scrollDuration) {
                    // Measure settle drift against the top row at t+0 (what the user sees), not the pre-scroll anchor.
                    let t0Snap = chat.debugScrollAnchorSnapshot()
                    let t0Offset = chat.debugContentOffsetY()
                    DispatchQueue.main.asyncAfter(deadline: .now() + settleMs) {
                        chat.debugWaitForReadingHistoryStable(maxAttempts: pacing.stableMaxAttempts) {
                            if chat.debugVisibleActionChromeFlickerCount() > 0 {
                                flickerFailures += 1
                                log("study-flicker step=\(step)")
                            }
                            let settleJitter = abs(chat.debugContentOffsetY() - t0Offset)
                            if settleJitter > 12 {
                                jumpFailures += 1
                                log("study-jump step=\(step) settle-jitter=\(Int(settleJitter))pt")
                            }
                            if let t0 = t0Snap,
                               let jump = chat.debugScrollJumpSince(anchor: t0, maxAllowed: 12) {
                                jumpFailures += 1
                                log("study-jump step=\(step) row=\(jump.row) drift=\(Int(jump.delta))pt")
                            }
                            _ = anchor
                            let blank = chat.debugVisibleStudyBlankState()
                            if blank.unrenderedAssistants > 0 || blank.interRowGaps > 0
                                || (blank.inflatedRows > 0 && blank.maxRowSlackPt > 48) {
                                blankFailures += 1
                                log("study-blank-scroll step=\(step) unrendered=\(blank.unrenderedAssistants) inflated=\(blank.inflatedRows) gaps=\(blank.interRowGaps) maxSlack=\(Int(blank.maxRowSlackPt))pt")
                            }
                            let qa = chat.debugVisibleCrossQAState()
                            if qa.unrenderedAssistants > 0 || qa.missingActionButtons > 0 {
                                renderFailures += 1
                                log("study-render step=\(step) unrendered=\(qa.unrenderedAssistants) missingActions=\(qa.missingActionButtons)")
                            }
                            let clipped = chat.debugVisibleRowClipCount()
                            if clipped > 0 {
                                clipFailures += 1
                                log("study-clip step=\(step) rows=\(clipped)")
                            }
                            step += 1
                            next()
                        }
                    }
                }
            }
            next()
        }
    }

    // MARK: - Orientation matrix (pure chat + study PDF, portrait ↔ landscape)

    private final class MatrixMetrics {
        var jumpFailures = 0
        var renderFailures = 0
        var clipFailures = 0
        var blankFailures = 0
        var chromeLateFailures = 0
        var chromeShiftFailures = 0
        var flickerFailures = 0
    }

    private static func auditMatrixFrame(chat: ChatViewController,
                                         metrics: MatrixMetrics,
                                         phase: String,
                                         step: Int,
                                         label: String,
                                         studyBlank: Bool,
                                         checkRender: Bool,
                                         checkClip: Bool = true) {
        if studyBlank && checkRender {
            let blank = chat.debugVisibleStudyBlankState()
            if blank.unrenderedAssistants > 0 || blank.interRowGaps > 0
                || (blank.inflatedRows > 0 && blank.maxRowSlackPt > 48) {
                metrics.blankFailures += 1
                log("\(phase) blank \(label) step=\(step) unrendered=\(blank.unrenderedAssistants) inflated=\(blank.inflatedRows) gaps=\(blank.interRowGaps) maxSlack=\(Int(blank.maxRowSlackPt))pt")
            }
        }
        if checkRender {
            let qa = chat.debugVisibleCrossQAState()
            if qa.unrenderedAssistants > 0 || qa.missingActionButtons > 0 {
                metrics.renderFailures += 1
                log("\(phase) render \(label) step=\(step) unrendered=\(qa.unrenderedAssistants) missingActions=\(qa.missingActionButtons)")
            }
        }
        if checkClip {
            let clipped = chat.debugVisibleRowClipCount()
            if clipped > 0 {
                metrics.clipFailures += 1
                log("\(phase) clip \(label) step=\(step) rows=\(clipped)")
            }
        }
        let flicker = chat.debugVisibleActionChromeFlickerCount()
        if flicker > 0 && checkRender {
            metrics.flickerFailures += 1
            log("\(phase) flicker \(label) step=\(step) rows=\(flicker)")
        }
    }

    private static func runMatrix(on chat: ChatViewController,
                                  metrics: MatrixMetrics? = nil,
                                  exitOnFinish: Bool = true,
                                  completion: ((Bool) -> Void)? = nil) {
        let metrics = metrics ?? MatrixMetrics()
        chat.loadViewIfNeeded()
        chat.reloadChat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let messages = ConversationStore.shared.currentConversation?.messages,
                  messages.count >= studyTurnCount * 2 else {
                log("FAIL matrix: missing fixture (need -ScrollStressStudyFixture)")
                completion?(false)
                if exitOnFinish { exit(1) }
                return
            }
            let phases: [(name: String, width: CGFloat, studyBlank: Bool, steps: Int, setup: (@escaping () -> Void) -> Void)] = [
                (
                    "chat-portrait",
                    portraitChatTableWidth,
                    false,
                    6,
                    { done in
                        chat.setStudyChrome(.none)
                        chat.debugSimulateLayoutWidthChange(tableWidth: portraitChatTableWidth, completion: done)
                    }
                ),
                (
                    "chat-landscape",
                    fullChatTableWidth,
                    false,
                    6,
                    { done in
                        chat.debugPersistHeightCacheForCurrentWidth()
                        chat.setStudyChrome(.none)
                        chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth, completion: done)
                    }
                ),
                (
                    "study-portrait",
                    portraitChatTableWidth,
                    true,
                    6,
                    { done in
                        chat.debugPersistHeightCacheForCurrentWidth()
                        chat.debugPinToBottom {
                            chat.debugEnterStudyPortraitPanel(tableWidth: portraitChatTableWidth) {
                                chat.debugWaitForStudyRelayoutStable(completion: done)
                            }
                        }
                    }
                ),
                (
                    "study-landscape",
                    studyPanelTableWidth,
                    true,
                    8,
                    { done in
                        chat.debugPersistHeightCacheForCurrentWidth()
                        chat.debugPinToBottom {
                            // Warm path: full-width chat before narrow PDF panel (stale heights → blank rows).
                            chat.setStudyChrome(.none)
                            chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                                chat.debugPersistHeightCacheForCurrentWidth()
                                chat.debugEnterStudyPanel(tableWidth: studyPanelTableWidth) {
                                    chat.debugWaitForStudyRelayoutStable(completion: done)
                                }
                            }
                        }
                    }
                ),
                (
                    "chat-landscape-return",
                    fullChatTableWidth,
                    false,
                    4,
                    { done in
                        chat.debugPersistHeightCacheForCurrentWidth()
                        chat.setStudyChrome(.none)
                        chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth, completion: done)
                    }
                )
            ]

            func runPhase(_ index: Int) {
                guard index < phases.count else {
                    finishMatrix(chat: chat, metrics: metrics, exitOnFinish: exitOnFinish, completion: completion)
                    return
                }
                let phase = phases[index]
                log("matrix phase \(index + 1)/\(phases.count): \(phase.name) w=\(Int(phase.width))")
                phase.setup {
                    auditMatrixFrame(
                        chat: chat,
                        metrics: metrics,
                        phase: phase.name,
                        step: -1,
                        label: "entry",
                        studyBlank: phase.studyBlank,
                        checkRender: true
                    )
                    runMatrixScrollPhase(
                        chat: chat,
                        phase: phase.name,
                        steps: phase.steps,
                        studyBlank: phase.studyBlank,
                        metrics: metrics
                    ) {
                        runPhase(index + 1)
                    }
                }
            }
            runPhase(0)
        }
    }

    private static func runMatrixScrollPhase(chat: ChatViewController,
                                             phase: String,
                                             steps: Int,
                                             studyBlank: Bool,
                                             metrics: MatrixMetrics,
                                             completion: @escaping () -> Void) {
        var step = 0
        let phaseSteps = mixedPacingMode
            ? max(steps, studyBlank ? 12 : 10)
            : (ultraSlowMode ? max(steps, studyBlank ? 10 : 8) : steps)

        func next() {
            guard step < phaseSteps else {
                completion()
                return
            }
            let profile = profileForStep(step)
            let pacing = mixedPacingMode
                ? ScrollPacing.forProfile(profile, mathHeavy: true, studyBlank: studyBlank)
                : ScrollPacing.matrix(studyBlank: studyBlank)
            let settleMs = pacing.settleMs
            let driftAllowance = pacing.driftAllowance
            if mixedPacingMode || ultraSlowMode {
                let distancePreview = scrollDistance(step: step, profile: profile, style: .matrix)
                log("\(phase)-\(profile.rawValue) step=\(step + 1)/\(phaseSteps) dist=\(Int(distancePreview)) dur=\(String(format: "%.2f", pacing.scrollDuration))s")
            }
            let anchor = chat.debugScrollAnchorSnapshot()
            let distance = scrollDistance(step: step, profile: profile, style: .matrix)
            let scrollDuration = pacing.scrollDuration
            let baselineBefore = chat.debugVisibleActionChromeSnapshot().buttonViewportY
            scheduleMidScrollSamples(
                chat: chat,
                pacing: pacing,
                scrollDuration: scrollDuration,
                step: step,
                labelPrefix: phase,
                studyBlank: studyBlank,
                onClip: { metrics.clipFailures += 1 },
                onBlank: { metrics.blankFailures += 1 },
                onChromeLate: { metrics.chromeLateFailures += 1 },
                onFlicker: { metrics.flickerFailures += 1 },
                baseline: baselineBefore
            )
            chat.debugSimulateSlowScrollUp(distance: distance, duration: scrollDuration) {
                let baseline = chat.debugVisibleActionChromeSnapshot().buttonViewportY
                schedulePostScrollSamples(
                    chat: chat,
                    pacing: pacing,
                    step: step,
                    labelPrefix: phase,
                    onChromeLate: { metrics.chromeLateFailures += 1 }
                )
                auditMatrixFrame(
                    chat: chat,
                    metrics: metrics,
                    phase: phase,
                    step: step,
                    label: "t+0",
                    studyBlank: studyBlank,
                    checkRender: false,
                    checkClip: profile == .fast || pacing.midScrollFractions.isEmpty
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.048) {
                    let snap = chat.debugVisibleActionChromeSnapshot()
                    if snap.missingButtons > 0 && (profile == .fast || pacing.midScrollFractions.isEmpty) {
                        metrics.chromeLateFailures += 1
                        log("\(phase) chrome-late step=\(step) profile=\(profile.rawValue) missing=\(snap.missingButtons)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + settleMs) {
                    chat.debugWaitForReadingHistoryStable(maxAttempts: pacing.stableMaxAttempts) {
                        if let anchor = anchor {
                            let expectedY = anchor.viewportY + distance
                            if let drift = chat.debugViewportDrift(
                                row: anchor.row,
                                expectedY: expectedY,
                                maxAllowed: driftAllowance
                            ) {
                                metrics.jumpFailures += 1
                                log("\(phase) jump step=\(step) row=\(anchor.row) drift=\(Int(drift))pt")
                            }
                        }
                        auditMatrixFrame(
                            chat: chat,
                            metrics: metrics,
                            phase: phase,
                            step: step,
                            label: "t+settle",
                            studyBlank: studyBlank,
                            checkRender: true
                        )
                        if !baseline.isEmpty {
                            let snap = chat.debugVisibleActionChromeSnapshot()
                            for (row, y0) in baseline {
                                guard let y1 = snap.buttonViewportY[row] else { continue }
                                if abs(y1 - y0) > pacing.chromeShiftTolerance {
                                    metrics.chromeShiftFailures += 1
                                    log("\(phase) chrome-shift step=\(step) row=\(row) delta=\(Int(abs(y1 - y0)))pt")
                                }
                            }
                        }
                        step += 1
                        next()
                    }
                }
            }
        }
        next()
    }

    private static func finishMatrix(chat: ChatViewController,
                                     metrics: MatrixMetrics,
                                     label: String? = nil,
                                     exitOnFinish: Bool = true,
                                     completion: ((Bool) -> Void)? = nil) {
        chat.debugClearLayoutWidthOverride()
        chat.setStudyChrome(.none)
        let failed = metrics.jumpFailures + metrics.renderFailures + metrics.clipFailures
            + metrics.blankFailures + metrics.chromeLateFailures + metrics.chromeShiftFailures
            + metrics.flickerFailures
        let suite = label ?? (firstOpenMode
            ? "first-open QA-edge (portrait/landscape chat + study)"
            : "orientation matrix (chat + study portrait/landscape)")
        let pass = failed == 0
        if pass {
            log("PASS \(suite)\(pacingSuffix())")
        } else {
            if metrics.blankFailures > 0 { log("FAIL matrix blank \(metrics.blankFailures)") }
            if metrics.jumpFailures > 0 { log("FAIL matrix jumps \(metrics.jumpFailures)") }
            if metrics.renderFailures > 0 { log("FAIL matrix render \(metrics.renderFailures)") }
            if metrics.clipFailures > 0 { log("FAIL matrix clip \(metrics.clipFailures)") }
            if metrics.chromeLateFailures > 0 { log("FAIL matrix chrome-late \(metrics.chromeLateFailures)") }
            if metrics.chromeShiftFailures > 0 { log("FAIL matrix chrome-shift \(metrics.chromeShiftFailures)") }
            if metrics.flickerFailures > 0 { log("FAIL matrix flicker \(metrics.flickerFailures)") }
        }
        fflush(stderr)
        completion?(pass)
        if exitOnFinish { exit(pass ? 0 : 1) }
    }

    // MARK: - Relaunch QA jitter (multi-conversation cold opens + first QA cross)

    private static func installRelaunchConversations(count: Int = 3, turns: Int = 8) -> [String] {
        let store = ConversationStore.shared
        var ids: [String] = []
        for i in 1...count {
            let conv = store.createConversation()
            store.updateCurrentQuietly { conversation in
                conversation.title = "首开抖动压测 #\(i) \(turns)轮"
                conversation.messages.removeAll()
                for turn in 1...turns {
                    conversation.messages.append(ChatMessage(
                        role: .user,
                        content: "问题 \(turn)：请推导方差公式、写出期望与方差的关系，并给出一个数值例子。"
                    ))
                    conversation.messages.append(ChatMessage(
                        role: .assistant,
                        content: mathHeavyAssistantBody(turn: turn),
                        reasoningContent: turn.isMultiple(of: 2) ? "先展开期望，再用独立同分布假设。" : "",
                        isStreaming: false
                    ))
                }
            }
            ids.append(conv.id)
        }
        log("installed \(count) relaunch conversations × \(turns) turns")
        return ids
    }

    private static func runRelaunchQA(on chat: ChatViewController) {
        chat.loadViewIfNeeded()
        let conversationIDs = installRelaunchConversations()
        let metrics = MatrixMetrics()
        let modes: [(name: String, width: CGFloat, study: Bool)] = [
            ("chat-portrait", portraitChatTableWidth, false),
            ("chat-landscape", fullChatTableWidth, false),
            ("study-portrait", portraitChatTableWidth, true),
            ("study-landscape", studyPanelTableWidth, true)
        ]
        let reopenPasses = 2

        func runMode(_ modeIndex: Int) {
            guard modeIndex < modes.count else {
                finishMatrix(chat: chat, metrics: metrics, label: "relaunch QA jitter")
                return
            }
            let mode = modes[modeIndex]
            log("relaunch mode \(modeIndex + 1)/\(modes.count): \(mode.name)")

            func runConversation(_ convIndex: Int) {
                guard convIndex < conversationIDs.count else {
                    runMode(modeIndex + 1)
                    return
                }
                let cid = conversationIDs[convIndex]
                ConversationStore.shared.selectConversation(id: cid)
                chat.reloadChat()

                func setupChrome(_ done: @escaping () -> Void) {
                    if mode.study {
                        if mode.width <= studyPanelTableWidth + 1 {
                            chat.setStudyChrome(.none)
                            chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                                chat.debugEnterStudyPanel(tableWidth: studyPanelTableWidth, completion: done)
                            }
                        } else {
                            chat.debugEnterStudyPortraitPanel(tableWidth: mode.width, completion: done)
                        }
                    } else {
                        chat.setStudyChrome(.none)
                        chat.debugSimulateLayoutWidthChange(tableWidth: mode.width, completion: done)
                    }
                }

                func runReopen(_ pass: Int) {
                    guard pass < reopenPasses else {
                        runConversation(convIndex + 1)
                        return
                    }
                    let phase = "\(mode.name)-c\(convIndex + 1)-open\(pass + 1)"
                    setupChrome {
                        chat.debugWaitForStudyRelayoutStable {
                            chat.debugSimulateColdOpen {
                                runFirstQACrossJitter(
                                    chat: chat,
                                    phase: phase,
                                    studyBlank: mode.study,
                                    metrics: metrics
                                ) {
                                    runReopen(pass + 1)
                                }
                            }
                        }
                    }
                }
                runReopen(0)
            }
            runConversation(0)
        }
        runMode(0)
    }

    /// Cold-open first QA-edge scroll with tight t+0 → t+settle micro-drift checks.
    private static func runFirstQACrossJitter(chat: ChatViewController,
                                              phase: String,
                                              studyBlank: Bool,
                                              metrics: MatrixMetrics,
                                              completion: @escaping () -> Void) {
        let distance = min(chat.debugSuggestedQAEdgeScrollDelta() ?? 72, 96)
        let anchor = chat.debugScrollAnchorSnapshot()
        let offset0 = chat.debugContentOffsetY()
        log("\(phase) first-qa dist=\(Int(distance)) offset=\(Int(offset0))")
        chat.debugSimulateSlowScrollUp(distance: distance, duration: 0.18) {
            let t0Anchor = chat.debugScrollAnchorSnapshot()
            let t0Offset = chat.debugContentOffsetY()
            let edge = chat.debugVisibleQAEdgeState()
            log("\(phase) t+0 topUsers=\(edge.userRowsAtTopEdge) offset=\(Int(t0Offset))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                chat.debugWaitForReadingHistoryStable(maxAttempts: 120) {
                    let t1Offset = chat.debugContentOffsetY()
                    let settleOffsetDelta = abs(t1Offset - t0Offset)
                    // Prefer top-row stability; offset alone moves when above-row heights remount.
                    if let t0 = t0Anchor,
                       let jump = chat.debugScrollJumpSince(anchor: t0, maxAllowed: 10) {
                        metrics.jumpFailures += 1
                        log("\(phase) row-jitter row=\(jump.row) drift=\(Int(jump.delta))pt")
                    } else if settleOffsetDelta > 48 {
                        log("\(phase) settle-offset \(Int(settleOffsetDelta))pt (top-row stable, offset \(Int(t0Offset))→\(Int(t1Offset)))")
                    }
                    if let a0 = anchor {
                        let expectedY = a0.viewportY + distance
                        if let drift = chat.debugViewportDrift(row: a0.row, expectedY: expectedY, maxAllowed: 18) {
                            metrics.jumpFailures += 1
                            log("\(phase) jump row=\(a0.row) drift=\(Int(drift))pt")
                        }
                    }
                    auditMatrixFrame(
                        chat: chat,
                        metrics: metrics,
                        phase: phase,
                        step: 0,
                        label: "t+settle",
                        studyBlank: studyBlank,
                        checkRender: true
                    )
                    completion()
                }
            }
        }
    }

    // MARK: - Bubble wiggle near assistant (history reading)

    private static func runBubbleWiggle(on chat: ChatViewController) {
        chat.loadViewIfNeeded()
        chat.reloadChat()
        let metrics = MatrixMetrics()
        let phase = "bubble-wiggle-history"
        log("\(phase): scroll to first QA edge then oscillate near assistant bubble")
        chat.debugPersistHeightCacheForCurrentWidth()
        chat.debugPinToBottom {
            chat.debugSimulateColdOpen {
                guard let firstUser = chat.debugFirstUserRowIndex() else {
                    log("FAIL \(phase): no user rows")
                    exit(1)
                    return
                }
                let assistantRow = firstUser + 1
                chat.debugScrollUntilFirstUserAtTopEdge { reached in
                    guard reached else {
                        log("FAIL \(phase): did not reach first user at top")
                        exit(1)
                        return
                    }
                    let anchor = chat.debugScrollAnchorSnapshot()
                    let assistantY0 = chat.debugRowViewportY(row: assistantRow)
                    log("\(phase): pre-wiggle assistantY=\(assistantY0.map { Int($0) } ?? -1) offset=\(Int(chat.debugContentOffsetY()))")
                    chat.debugSimulateBubbleWiggle(amplitude: 60, halfCycles: 4, halfDuration: 0.16) {
                        chat.debugWaitForReadingHistoryStable(maxAttempts: 160) {
                            if let anchor = anchor,
                               let jump = chat.debugScrollJumpSince(anchor: anchor, maxAllowed: 20) {
                                metrics.jumpFailures += 1
                                log("\(phase) anchor-jump row=\(jump.row) drift=\(Int(jump.delta))pt t+settle")
                            }
                            if let y0 = assistantY0,
                               let y1 = chat.debugRowViewportY(row: assistantRow),
                               abs(y1 - y0) > 22 {
                                metrics.jumpFailures += 1
                                log("\(phase) assistant reposition \(Int(y0))→\(Int(y1))pt t+settle")
                            }
                            finishMatrix(chat: chat, metrics: metrics, label: phase)
                        }
                    }
                }
            }
        }
    }

    // MARK: - First user bubble at top (study-landscape anchor regression)

    private static func runFirstBubble(on chat: ChatViewController) {
        chat.loadViewIfNeeded()
        chat.reloadChat()
        let metrics = MatrixMetrics()
        let phase = "first-bubble-study-landscape"
        log("\(phase): cold open + scroll to first user bubble at top edge")
        chat.debugPersistHeightCacheForCurrentWidth()
        chat.debugPinToBottom {
            chat.setStudyChrome(.none)
            chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                chat.debugPersistHeightCacheForCurrentWidth()
                chat.debugEnterStudyPanel(tableWidth: studyPanelTableWidth) {
                    chat.debugWaitForStudyRelayoutStable {
                        chat.debugSimulateColdOpen {
                            guard let firstUser = chat.debugFirstUserRowIndex() else {
                                log("FAIL \(phase): no user rows")
                                exit(1)
                                return
                            }
                            log("\(phase): firstUserRow=\(firstUser) offset=\(Int(chat.debugContentOffsetY()))")
                            chat.debugScrollUntilFirstUserAtTopEdge { reached in
                                guard reached else {
                                    log("FAIL \(phase): did not reach first user at top edge")
                                    exit(1)
                                    return
                                }
                                let edge = chat.debugVisibleQAEdgeState()
                                log("\(phase): reached topUsers=\(edge.userRowsAtTopEdge) nearAssistants=\(edge.assistantRowsNearUserEdge)")
                                let userY = chat.debugRowViewportY(row: firstUser)
                                let assistantY = chat.debugRowViewportY(row: firstUser + 1)
                                log("\(phase): t+0 userY=\(userY.map { Int($0) } ?? -1) assistantY=\(assistantY.map { Int($0) } ?? -1)")
                                let anchor = chat.debugScrollAnchorSnapshot()
                                // Micro QA-edge steps while first user straddles top — reproduces manual overshoot settle.
                                chat.debugSimulateSlowScrollUp(distance: 28, duration: 0.22) {
                                    let microUserY = chat.debugRowViewportY(row: firstUser)
                                    let microAssistantY = chat.debugRowViewportY(row: firstUser + 1)
                                    log("\(phase): micro userY=\(microUserY.map { Int($0) } ?? -1) assistantY=\(microAssistantY.map { Int($0) } ?? -1)")
                                    chat.debugWaitForReadingHistoryStable {
                                        if let anchor = anchor,
                                           let jump = chat.debugScrollJumpSince(anchor: anchor, maxAllowed: 24) {
                                            metrics.jumpFailures += 1
                                            log("\(phase) jump row=\(jump.row) drift=\(Int(jump.delta))pt t+settle")
                                        }
                                        if let userY0 = userY,
                                           let userY1 = chat.debugRowViewportY(row: firstUser),
                                           abs(userY1 - userY0) > 20 {
                                            metrics.jumpFailures += 1
                                            log("\(phase) user-bubble reposition \(Int(userY0))→\(Int(userY1))pt t+settle")
                                        }
                                        if firstUser + 1 < (ConversationStore.shared.currentConversation?.messages.count ?? 0),
                                           let assistantY0 = assistantY,
                                           let assistantY1 = chat.debugRowViewportY(row: firstUser + 1),
                                           assistantY1 - assistantY0 > 18 {
                                            metrics.jumpFailures += 1
                                            log("\(phase) assistant-body snap +\(Int(assistantY1 - assistantY0))pt t+settle (into 正文)")
                                        }
                                        auditMatrixFrame(
                                            chat: chat,
                                            metrics: metrics,
                                            phase: phase,
                                            step: 0,
                                            label: "t+settle",
                                            studyBlank: true,
                                            checkRender: true
                                        )
                                        finishMatrix(
                                            chat: chat,
                                            metrics: metrics,
                                            label: "first-bubble study-landscape"
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - First-open QA edge (cold open + micro scroll at user-bubble boundaries)

    private static func runFirstOpen(on chat: ChatViewController,
                                     metrics: MatrixMetrics? = nil,
                                     exitOnFinish: Bool = true,
                                     completion: ((Bool) -> Void)? = nil) {
        let metrics = metrics ?? MatrixMetrics()
        chat.loadViewIfNeeded()
        chat.reloadChat()
        let pacing = ScrollPacing.chat(mathHeavy: true)

        let phases: [(name: String, width: CGFloat, studyBlank: Bool, setup: (@escaping () -> Void) -> Void)] = [
            (
                "cold-chat-portrait",
                portraitChatTableWidth,
                false,
                { done in
                    chat.setStudyChrome(.none)
                    chat.debugSimulateLayoutWidthChange(tableWidth: portraitChatTableWidth) {
                        chat.debugSimulateColdOpen(completion: done)
                    }
                }
            ),
            (
                "cold-chat-landscape",
                fullChatTableWidth,
                false,
                { done in
                    chat.debugPersistHeightCacheForCurrentWidth()
                    chat.setStudyChrome(.none)
                    chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                        chat.debugSimulateColdOpen(completion: done)
                    }
                }
            ),
            (
                "cold-study-portrait",
                portraitChatTableWidth,
                true,
                { done in
                    chat.debugPersistHeightCacheForCurrentWidth()
                    chat.debugPinToBottom {
                        chat.debugEnterStudyPortraitPanel(tableWidth: portraitChatTableWidth) {
                            chat.debugWaitForStudyRelayoutStable {
                                chat.debugSimulateColdOpen(completion: done)
                            }
                        }
                    }
                }
            ),
            (
                "cold-study-landscape",
                studyPanelTableWidth,
                true,
                { done in
                    chat.debugPersistHeightCacheForCurrentWidth()
                    chat.debugPinToBottom {
                        chat.setStudyChrome(.none)
                        chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                            chat.debugPersistHeightCacheForCurrentWidth()
                            chat.debugEnterStudyPanel(tableWidth: studyPanelTableWidth) {
                                chat.debugWaitForStudyRelayoutStable {
                                    chat.debugSimulateColdOpen(completion: done)
                                }
                            }
                        }
                    }
                }
            )
        ]

        func runPhase(_ index: Int) {
            guard index < phases.count else {
                finishMatrix(chat: chat, metrics: metrics, exitOnFinish: exitOnFinish, completion: completion)
                return
            }
            let phase = phases[index]
            log("first-open phase \(index + 1)/\(phases.count): \(phase.name) w=\(Int(phase.width))")
            phase.setup {
                auditMatrixFrame(
                    chat: chat,
                    metrics: metrics,
                    phase: phase.name,
                    step: -1,
                    label: "cold-entry",
                    studyBlank: phase.studyBlank,
                    checkRender: true
                )
                runFirstOpenQAEdgeSteps(
                    chat: chat,
                    phase: phase.name,
                    studyBlank: phase.studyBlank,
                    pacing: pacing,
                    metrics: metrics
                ) {
                    runPhase(index + 1)
                }
            }
        }
        runPhase(0)
    }

    private static func runFirstOpenQAEdgeSteps(chat: ChatViewController,
                                                phase: String,
                                                studyBlank: Bool,
                                                pacing fallbackPacing: ScrollPacing,
                                                metrics: MatrixMetrics,
                                                completion: @escaping () -> Void) {
        let maxSteps = mixedPacingMode ? 16 : (ultraSlowMode ? 14 : 8)
        var step = 0

        func auditEdge(_ label: String) {
            let edge = chat.debugVisibleQAEdgeState()
            if !edge.userRowsAtTopEdge.isEmpty || !edge.userRowsAtBottomEdge.isEmpty {
                log("\(phase) qa-edge \(label) step=\(step) topUsers=\(edge.userRowsAtTopEdge) bottomUsers=\(edge.userRowsAtBottomEdge) nearAssistants=\(edge.assistantRowsNearUserEdge) uncommitted=\(edge.uncommittedAssistantsNearEdge)")
            }
            auditMatrixFrame(
                chat: chat,
                metrics: metrics,
                phase: phase,
                step: step,
                label: label,
                studyBlank: studyBlank,
                checkRender: true
            )
            let snap = chat.debugVisibleActionChromeSnapshot()
            if snap.missingButtons > 0 {
                metrics.chromeLateFailures += 1
                log("\(phase) chrome-late \(label) step=\(step) missing=\(snap.missingButtons)")
            }
        }

        func next() {
            guard step < maxSteps else {
                completion()
                return
            }
            let profile = profileForStep(step)
            let pacing = mixedPacingMode
                ? ScrollPacing.forProfile(profile, mathHeavy: true, studyBlank: studyBlank)
                : fallbackPacing
            let suggested = chat.debugSuggestedQAEdgeScrollDelta()
            let fallbackDistance = scrollDistance(step: step, profile: profile, style: .qaEdge)
            let distanceCap: CGFloat = profile == .fast ? 160 : (profile == .ultra ? 96 : 120)
            let distance = min(suggested ?? fallbackDistance, distanceCap)
            if mixedPacingMode || ultraSlowMode {
                log("\(phase)-\(profile.rawValue) qa step=\(step + 1)/\(maxSteps) dist=\(Int(distance)) dur=\(String(format: "%.2f", pacing.scrollDuration))s")
            }
            let anchor = chat.debugScrollAnchorSnapshot()
            let scrollDuration: TimeInterval
            switch profile {
            case .fast:
                scrollDuration = 0.12
            case .ultra:
                scrollDuration = pacing.scrollDuration * 0.55
            case .slow:
                scrollDuration = pacing.scrollDuration * 0.4
            }
            scheduleMidScrollSamples(
                chat: chat,
                pacing: pacing,
                scrollDuration: scrollDuration,
                step: step,
                labelPrefix: "\(phase)-qa",
                studyBlank: studyBlank,
                onClip: { metrics.clipFailures += 1 },
                onBlank: { metrics.blankFailures += 1 },
                onChromeLate: { metrics.chromeLateFailures += 1 },
                onFlicker: { metrics.flickerFailures += 1 },
                baseline: chat.debugVisibleActionChromeSnapshot().buttonViewportY
            )
                chat.debugSimulateSlowScrollUp(distance: distance, duration: scrollDuration) {
                auditEdge("t+0")
                let t0Offset = chat.debugContentOffsetY()
                let t0RowAnchor = chat.debugScrollAnchorSnapshot()
                let t0ChromeRel = chat.debugVisibleActionChromeSnapshot().buttonRowRelativeY
                schedulePostScrollSamples(
                    chat: chat,
                    pacing: pacing,
                    step: step,
                    labelPrefix: "\(phase)-qa",
                    onChromeLate: { metrics.chromeLateFailures += 1 }
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + pacing.settleMs) {
                    chat.debugWaitForReadingHistoryStable(maxAttempts: pacing.stableMaxAttempts) {
                        auditEdge("t+settle")
                        // Judge chrome against t+0 using row-relative Y (above-row remounts
                        // move absolute viewport Y even when buttons stay glued to their row).
                        if !t0ChromeRel.isEmpty {
                            let settleChrome = chat.debugVisibleActionChromeSnapshot().buttonRowRelativeY
                            for (row, y0) in t0ChromeRel {
                                guard let y1 = settleChrome[row] else { continue }
                                let excess = abs(y1 - y0)
                                if excess > pacing.chromeShiftTolerance {
                                    metrics.chromeShiftFailures += 1
                                    log("\(phase) chrome-shift step=\(step) row=\(row) excess=\(Int(excess))pt t+settle")
                                }
                            }
                        }
                        if let anchor = anchor {
                            let expectedY = anchor.viewportY + distance
                            if let drift = chat.debugViewportDrift(
                                row: anchor.row,
                                expectedY: expectedY,
                                maxAllowed: pacing.driftAllowance
                            ) {
                                metrics.jumpFailures += 1
                                log("\(phase) jump step=\(step) row=\(anchor.row) drift=\(Int(drift))pt")
                            }
                        }
                        // Offset may move when heights above the top row remount during settle;
                        // judge by the top visible row (same as study-panel stress).
                        let settleOffsetDelta = abs(chat.debugContentOffsetY() - t0Offset)
                        if let t0 = t0RowAnchor,
                           let jump = chat.debugScrollJumpSince(anchor: t0, maxAllowed: 10) {
                            metrics.jumpFailures += 1
                            log("\(phase) row-jitter step=\(step) row=\(jump.row) drift=\(Int(jump.delta))pt")
                        } else if settleOffsetDelta > 48 {
                            // Top row stable: offset remount is expected when heights above change.
                            log("\(phase) settle-offset step=\(step) \(Int(settleOffsetDelta))pt (top-row stable)")
                        }
                        step += 1
                        next()
                    }
                }
            }
        }
        next()
    }

    // MARK: - Diverse (mixed fast+ultra: chat → first-open → matrix)

    private static func installMathHeavyChatFixture() {
        let store = ConversationStore.shared
        store.updateCurrentQuietly { conversation in
            conversation.title = "公式压测 实数完备性 \(turnCount)轮"
            conversation.messages.removeAll()
            for turn in 1...turnCount {
                conversation.messages.append(ChatMessage(
                    role: .user,
                    content: userQuestion(turn: turn)
                ))
                conversation.messages.append(ChatMessage(
                    role: .assistant,
                    content: mathHeavyAssistantBody(turn: turn),
                    reasoningContent: turn.isMultiple(of: 2) ? "先展开期望，再用独立同分布假设，最后代入具体数字。" : "",
                    isStreaming: false
                ))
            }
        }
        log("installed \(turnCount)-turn math-heavy chat fixture")
    }

    private static func runDiverse(on chat: ChatViewController) {
        log("diverse phase 1/3: mixed chat scroll (math-heavy)")
        installMathHeavyChatFixture()
        chat.loadViewIfNeeded()
        chat.reloadChat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let messages = ConversationStore.shared.currentConversation?.messages {
                let assistants = messages.filter { $0.role == .assistant && !$0.isStreaming }
                let width = chat.debugLayoutContentWidth()
                log("prewarming \(assistants.count) math-heavy assistant layouts")
                AssistantMessageLayout.prewarmLayouts(
                    for: assistants,
                    targetWidth: width,
                    layoutLimit: assistants.count
                )
                chat.debugSeedCommittedHeightsFromLayoutCache()
            }
            runScrollSteps(on: chat, exitOnFinish: false) { chatPass in
                log("diverse phase 2/3: mixed first-open QA-edge")
                installStudyFixture()
                chat.reloadChat()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    runFirstOpen(on: chat, exitOnFinish: false) { firstOpenPass in
                        log("diverse phase 3/3: mixed orientation matrix")
                        installStudyFixture()
                        chat.reloadChat()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            runMatrix(on: chat, exitOnFinish: false) { matrixPass in
                                chat.debugClearLayoutWidthOverride()
                                chat.setStudyChrome(.none)
                                let pass = chatPass && firstOpenPass && matrixPass
                                if pass {
                                    log("PASS diverse stress suite (chat + first-open + matrix)\(pacingSuffix())")
                                } else {
                                    log("FAIL diverse stress suite chat=\(chatPass ? "ok" : "FAIL") firstOpen=\(firstOpenPass ? "ok" : "FAIL") matrix=\(matrixPass ? "ok" : "FAIL")")
                                }
                                fflush(stderr)
                                exit(pass ? 0 : 1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Ultra switch (cold open + mid-scroll width/study toggles)

    private static func runUltraSwitch(on chat: ChatViewController) {
        chat.loadViewIfNeeded()
        chat.reloadChat()
        let metrics = MatrixMetrics()

        func finish() {
            finishMatrix(chat: chat, metrics: metrics)
        }

        func scroll(_ phase: String, steps: Int, studyBlank: Bool, then: @escaping () -> Void) {
            runMatrixScrollPhase(
                chat: chat,
                phase: phase,
                steps: steps,
                studyBlank: studyBlank,
                metrics: metrics,
                completion: then
            )
        }

        log("ultra-switch phase 1/5: cold-open chat scroll")
        chat.debugSimulateColdOpen {
            scroll("cold-open-chat", steps: 6, studyBlank: false) {
                log("ultra-switch phase 2/5: portrait chat + mid width toggle")
                chat.setStudyChrome(.none)
                chat.debugSimulateLayoutWidthChange(tableWidth: portraitChatTableWidth) {
                    scroll("chat-portrait-pre", steps: 2, studyBlank: false) {
                        let pacing = ScrollPacing.chat(mathHeavy: true)
                        chat.debugSimulateSlowScrollUp(distance: 100, duration: pacing.scrollDuration * 0.45) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + pacing.scrollDuration * 0.3) {
                                chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                                    scroll("chat-landscape-post-toggle", steps: 4, studyBlank: false) {
                                        log("ultra-switch phase 3/5: cold-open study narrow")
                                        chat.debugSimulateColdOpen {
                                            chat.debugPinToBottom {
                                                chat.setStudyChrome(.none)
                                                chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                                                    chat.debugPersistHeightCacheForCurrentWidth()
                                                    chat.debugEnterStudyPanel(tableWidth: studyPanelTableWidth) {
                                                        chat.debugWaitForStudyRelayoutStable {
                                                            scroll("cold-study-landscape", steps: 6, studyBlank: true) {
                                                                log("ultra-switch phase 4/5: study portrait↔landscape mid-scroll")
                                                                chat.debugPersistHeightCacheForCurrentWidth()
                                                                chat.debugEnterStudyPortraitPanel(tableWidth: portraitChatTableWidth) {
                                                                    chat.debugWaitForStudyRelayoutStable {
                                                                        scroll("study-portrait", steps: 2, studyBlank: true) {
                                                                            chat.debugSimulateSlowScrollUp(distance: 90, duration: pacing.scrollDuration * 0.4) {
                                                                                DispatchQueue.main.asyncAfter(deadline: .now() + pacing.scrollDuration * 0.25) {
                                                                                    chat.setStudyChrome(.none)
                                                                                    chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                                                                                        chat.debugPersistHeightCacheForCurrentWidth()
                                                                                        chat.debugEnterStudyPanel(tableWidth: studyPanelTableWidth) {
                                                                                            chat.debugWaitForStudyRelayoutStable {
                                                                                                scroll("study-landscape-toggle", steps: 4, studyBlank: true) {
                                                                                                    log("ultra-switch phase 5/5: exit study cold scroll")
                                                                                                    chat.debugSimulateColdOpen {
                                                                                                        chat.setStudyChrome(.none)
                                                                                                        chat.debugSimulateLayoutWidthChange(tableWidth: fullChatTableWidth) {
                                                                                                            scroll("cold-chat-return", steps: 4, studyBlank: false, then: finish)
                                                                                                        }
                                                                                                    }
                                                                                                }
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func studyUserQuestion(turn: Int) -> String {
        if turn == 1 {
            return "冲激信号有什么性质?"
        }
        return "第 \(turn) 问：线性卷积长度与范围怎么计算？请写出 y[n]=x[n]*h[n] 的求和式与支撑区间。"
    }

    private static func studyReasoning(turn: Int) -> String {
        if turn == 1 {
            return "先回忆 δ(t) 的筛选性质，再说明单位冲激与离散冲激的定义，最后归纳线性时不变系统对它的响应。"
        }
        return turn.isMultiple(of: 2)
            ? "先写离散卷积定义，再确定 x[n] 与 h[n] 的支撑，最后求 y[n] 的非零区间。"
            : ""
    }

    private static func studyAssistantBody(turn: Int) -> String {
        if turn == 1 {
            return """
            ## 单位冲激信号

            连续时间单位冲激 \\(\\delta(t)\\)（狄拉克分布）满足筛选性质：

            $$\\int_{-\\infty}^{\\infty} x(t)\\,\\delta(t-t_0)\\,dt = x(t_0)$$

            离散单位冲激：

            $$\\delta[n] = \\begin{cases}1,& n=0\\\\0,& n\\neq 0\\end{cases}$$

            对 LTI 系统，冲激响应 \\(h(t)\\) 完全决定系统：

            $$y(t) = x(t) * h(t) = \\int x(\\tau)\\,h(t-\\tau)\\,d\\tau$$
            """
        }
        return """
        ## 线性卷积 · 回合 \(turn)

        离散卷积定义：

        $$y[n] = (x * h)[n] = \\sum_{k=-\\infty}^{\\infty} x[k]\\,h[n-k]$$

        若 \\(x[n]\\) 支撑于 \\([n_x^-, n_x^+]\\)，\\(h[n]\\) 支撑于 \\([n_h^-, n_h^+]\\)，则

        $$y[n]\\neq 0 \\Rightarrow n_x^- + n_h^- \\le n \\le n_x^+ + n_h^+$$

        长度（非零样本数上界）：

        $$L_y \\le L_x + L_h - 1$$

        例：\\(x=\\{1,2\\}\\)，\\(h=\\{1,1,1\\}\\)，

        $$y[0]=1,\\; y[1]=3,\\; y[2]=2,\\; y[3]=0$$

        圆周卷积对比（DFT 长度 \\(N\\)）：

        $$y_N[n] = \\sum_{k=0}^{N-1} x[k]\\,h[(n-k)\\bmod N]$$

        > Study 窄宽浏览时不应出现 user↔assistant 间大块空白；公式 warm 后视口不应跳变。
        """
    }

    private static func runRotation(on chat: ChatViewController) {
        chat.loadViewIfNeeded()
        chat.reloadChat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let messages = ConversationStore.shared.currentConversation?.messages,
                  messages.count >= turnCount * 2 else {
                log("FAIL rotation: missing fixture (need -ScrollStressFixture)")
                return
            }
            let midRow = min(messages.count - 1, turnCount)
            log("begin rotation stress at row \(midRow)")
            chat.debugScrollToRow(midRow) {
                runRotationSteps(on: chat)
            }
        }
    }

    private static func runRotationSteps(on chat: ChatViewController) {
        let widths: [CGFloat] = [768, 1024, 768, 1024]
        var step = 0
        var clipFailures = 0
        var chromeFailures = 0
        var postScrollShiftFailures = 0
        let scrollDistance: CGFloat = 80

        func finish() {
            chat.debugClearLayoutWidthOverride()
            if clipFailures == 0, chromeFailures == 0, postScrollShiftFailures == 0 {
                log("PASS rotation stress \(widths.count) width toggles")
            } else {
                if clipFailures > 0 { log("FAIL \(clipFailures) row clips after rotation") }
                if chromeFailures > 0 { log("FAIL \(chromeFailures) missing action buttons after rotation") }
                if postScrollShiftFailures > 0 {
                    log("FAIL \(postScrollShiftFailures) chrome jitter after post-rotation scroll")
                }
            }
            fflush(stderr)
            exit(clipFailures == 0 && chromeFailures == 0 && postScrollShiftFailures == 0 ? 0 : 1)
        }

        func next() {
            guard step < widths.count else {
                finish()
                return
            }
            let width = widths[step]
            chat.debugSimulateLayoutWidthChange(tableWidth: width) {
                let clipped = chat.debugVisibleRowClipCount()
                if clipped > 0 {
                    clipFailures += 1
                    log("rotation clip step=\(step) width=\(Int(width)) rows=\(clipped)")
                }
                let qa = chat.debugVisibleCrossQAState()
                if qa.missingActionButtons > 0 {
                    chromeFailures += 1
                    log("rotation chrome step=\(step) width=\(Int(width)) missing=\(qa.missingActionButtons)")
                }
                let postRotateBaseline = chat.debugVisibleActionChromeSnapshot().buttonViewportY
                chat.debugSimulateSlowScrollUp(distance: scrollDistance, duration: 0.45) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        let postSnap = chat.debugVisibleActionChromeSnapshot()
                        for (row, y0) in postRotateBaseline where postSnap.buttonViewportY[row] != nil {
                            guard let y1 = postSnap.buttonViewportY[row] else { continue }
                            // Scrolling up moves chrome down in viewport — only flag excess jitter.
                            let expectedY = y0 + scrollDistance
                            if abs(y1 - expectedY) > 14 {
                                postScrollShiftFailures += 1
                                log("rotation post-scroll chrome step=\(step) row=\(row) excess=\(Int(abs(y1 - expectedY)))pt")
                            }
                        }
                        let clippedAfterScroll = chat.debugVisibleRowClipCount()
                        if clippedAfterScroll > 0 {
                            clipFailures += 1
                            log("rotation clip-after-scroll step=\(step) rows=\(clippedAfterScroll)")
                        }
                        step += 1
                        next()
                    }
                }
            }
        }
        next()
    }

    private static func assistantBody(turn: Int) -> String {
        """
        ## 回合 \(turn)

        样本均值 \\(\\bar{X}_n\\) 的方差为

        $$\\operatorname{Var}(\\bar{X}_n)
        = \\frac{1}{n^2}\\sum_{i=1}^n \\operatorname{Var}(X_i)
        = \\frac{\\sigma^2}{n}.$$

        | 项 | 含义 |
        |:---|---:|
        | \\(n\\) | 样本量 |
        | \\(\\sigma^2\\) | 总体方差 |

        > 独立同分布时，协方差项为 0。

        ```swift
        let variance = sigma * sigma / Double(n)
        ```

        行内公式 \\(E=mc^2\\) 与块级：

        $$\\int_0^t e^{-\\tau}\\,d\\tau = 1-e^{-t}$$

        补充说明段落 \(turn)：当 \\(n\\) 增大时，估计更稳定；重复滚动不应引起可见位移，三大按钮不应被裁切。
        """
    }

    private static let completenessTheorems: [(name: String, userPrompt: String, body: String)] = [
        (
            "确界原理",
            "请陈述并证明实数完备性的确界原理，说明任意非空有上界的集合必有上确界。",
            """
            ## 确界原理（最小上界公理）

            **定理**：若 \\(S\\subset\\mathbb{R}\\) 非空且有上界，则 \\(S\\) 有上确界 \\(\\sup S\\)。

            $$\\forall S\\subset\\mathbb{R},\\; S\\neq\\varnothing \\land (\\exists M,\\forall x\\in S, x\\le M)
            \\Rightarrow \\exists \\beta=\\sup S$$

            等价刻画：\\(\\beta\\) 是上界且任意 \\(\\varepsilon>0\\) 存在 \\(x\\in S\\) 使 \\(x>\\beta-\\varepsilon\\)。

            $$\\forall \\varepsilon>0,\\; \\exists x\\in S:\\; x > \\sup S - \\varepsilon$$

            与 Archimedean 性质结合可得：对任意 \\(x>0\\)，存在 \\(n\\in\\mathbb{N}\\) 使 \\(n>x\\)。

            $$\\forall x>0,\\; \\exists n\\in\\mathbb{N}:\\; n > x$$

            推论：单调有界数列收敛（见下一条）。
            """
        ),
        (
            "单调有界定理",
            "证明单调有界数列必收敛，并给出 \\(\\{a_n\\}\\) 单调递增有上界的证明框架。",
            """
            ## 单调有界定理

            若 \\(\\{a_n\\}\\) 单调递增且有上界，则 \\(\\{a_n\\}\\) 收敛。

            $$a_1\\le a_2\\le \\cdots \\le a_n\\le \\cdots \\le M
            \\Rightarrow \\lim_{n\\to\\infty} a_n = \\sup\\{a_n\\}$$

            **证明要点**：令 \\(S=\\{a_n\\}\\)，由确界原理得 \\(\\beta=\\sup S\\)。对任意 \\(\\varepsilon>0\\)，存在 \\(a_N>\\beta-\\varepsilon\\)，由单调性

            $$n\\ge N \\Rightarrow |a_n-\\beta|\\le |a_N-\\beta|<\\varepsilon$$

            递减情形：\\(\\lim a_n = \\inf\\{a_n\\}\\)。

            $$a_1\\ge a_2\\ge \\cdots \\Rightarrow \\lim a_n = \\inf\\{a_n\\}$$
            """
        ),
        (
            "区间套定理",
            "用区间套定理证明 \\(\\sqrt{2}\\) 存在，并写出闭区间套收敛条件。",
            """
            ## 区间套定理

            闭区间套 \\(\\{[a_n,b_n]\\}\\) 满足 \\([a_{n+1},b_{n+1}]\\subset[a_n,b_n]\\) 且 \\(b_n-a_n\\to 0\\)，则交集中恰有一点。

            $$[a_{n+1},b_{n+1}]\\subset[a_n,b_n],\\quad b_n-a_n\\to 0
            \\Rightarrow \\bigcap_{n=1}^{\\infty}[a_n,b_n]=\\{c\\}$$

            **\\(\\sqrt{2}\\) 存在性**：二分法构造

            $$a_1=1,\\; b_1=2,\\; a_{n+1}^2<2<b_{n+1}^2$$

            得唯一 \\(c\\) 使 \\(c^2=2\\)。

            长度趋于零：\\(b_n-a_n = \\dfrac{b_1-a_1}{2^{n-1}}\\to 0\\)。
            """
        ),
        (
            "波尔查诺-魏尔斯特拉斯定理",
            "证明有界数列必有收敛子列，并说明与紧致性的关系。",
            """
            ## 波尔查诺–魏尔斯特拉斯定理

            有界数列 \\(\\{x_n\\}\\subset\\mathbb{R}\\) 必有收敛子列。

            $$\\{x_n\\}\\ \\text{bounded} \\Rightarrow \\exists \\{n_k\\},\\; x_{n_k}\\to x_0$$

            **二分法证明梗概**：若 \\([a,b]\\) 含无穷多项，取半区间仍含无穷多项，得区间套 \\([a_k,b_k]\\)，交点 \\(x_0\\) 为子列极限。

            与 Heine–Borel 等价于 \\([a,b]\\) 序列紧致：

            $$\\text{BW} \\Leftrightarrow \\text{closed bounded }[a,b]\\text{ is sequentially compact}$$
            """
        ),
        (
            "柯西收敛准则",
            "写出柯西列定义，证明实数列收敛当且仅当它是柯西列。",
            """
            ## 柯西收敛准则

            \\(\\{a_n\\}\\subset\\mathbb{R}\\) 收敛 \\(\\Leftrightarrow\\) 它是柯西列：

            $$\\forall \\varepsilon>0,\\; \\exists N,\\; \\forall m,n>N:\\; |a_m-a_n|<\\varepsilon$$

            **必要性**：若 \\(a_n\\to L\\)，则

            $$|a_m-a_n|\\le |a_m-L|+|a_n-L|<\\frac{\\varepsilon}{2}+\\frac{\\varepsilon}{2}=\\varepsilon$$

            **充分性**：柯西列有界，由 BW 取子列 \\(a_{n_k}\\to L\\)，再证全列收敛于 \\(L\\)：

            $$|a_n-L|\\le |a_n-a_{n_k}|+|a_{n_k}-L|<\\varepsilon$$
            """
        ),
        (
            "有限覆盖定理",
            "陈述 Heine–Borel 有限覆盖定理并证明闭区间上的有限子覆盖性质。",
            """
            ## 有限覆盖定理（Heine–Borel）

            \\([a,b]\\) 的任意开覆盖有有限子覆盖。

            $$\\mathcal{U}=\\{U_\\lambda\\}_{\\lambda\\in\\Lambda}\\ \\text{open},\\;
            [a,b]\\subset\\bigcup_{\\lambda} U_\\lambda
            \\Rightarrow \\exists \\lambda_1,\\ldots,\\lambda_m,\\;
            [a,b]\\subset\\bigcup_{i=1}^m U_{\\lambda_i}$$

            等价于 \\([a,b]\\) 紧致。反证：若无有限子覆盖，二分法得区间套 \\([a_n,b_n]\\)，交点 \\(c\\) 被某 \\(U\\) 覆盖，与构造矛盾。

            $$c\\in U \\Rightarrow \\exists \\delta:\\; (c-\\delta,c+\\delta)\\subset U$$
            """
        ),
        (
            "戴德金分割原理",
            "介绍戴德金分割如何刻画实数完备性，并说明与确界原理等价。",
            """
            ## 戴德金分割原理

            有理数集 \\(\\mathbb{Q}\\) 的分割 \\((A|B)\\) 满足：\\(A\\cup B=\\mathbb{Q}\\)，\\(A\\cap B=\\varnothing\\)，\\(a<b\\) 对一切 \\(a\\in A, b\\in B\\)，且 \\(A\\) 无最大元。

            每个分割对应唯一实数 \\(r\\)：

            $$r = \\sup A = \\inf B$$

            完备性：任意有上界的非空 \\(S\\subset\\mathbb{R}\\) 有 \\(\\sup S\\)，与分割原理等价。

            $$S\\subset\\mathbb{R},\\; S\\neq\\varnothing,\\; \\exists M,\\forall x\\in S, x\\le M
            \\Rightarrow \\exists \\sup S\\in\\mathbb{R}$$
            """
        )
    ]

    private static func userQuestion(turn: Int) -> String {
        let item = completenessTheorems[(turn - 1) % completenessTheorems.count]
        return "第 \(turn) 问：\(item.userPrompt)"
    }

    private static func mathHeavyAssistantBody(turn: Int) -> String {
        let item = completenessTheorems[(turn - 1) % completenessTheorems.count]
        let k = (turn - 1) / completenessTheorems.count + 1
        return """
        \(item.body)

        ### 回合 \(turn) · 第 \(k) 轮推导

        七大定理等价链（概要）：

        $$\\text{确界} \\Leftrightarrow \\text{单调有界} \\Leftrightarrow \\text{区间套}
        \\Leftrightarrow \\text{BW} \\Leftrightarrow \\text{Cauchy} \\Leftrightarrow \\text{有限覆盖}
        \\Leftrightarrow \\text{Dedekind}$$

        行内：\\(\\mathbb{R}\\) 完备 \\(\\Leftrightarrow\\) Cauchy 列收敛；\\(\\{x_n\\}\\subset[a,b]\\) 必有收敛子列。

        数值感受：对 \\(S=\\{1-\\frac{1}{n}\\}\\)，\\(\\sup S = 1\\)；对 \\(a_n=1+\\frac{1}{n}\\)，\\(\\inf\\{a_n\\}=1\\)。

        $$\\sup\\left\\{1-\\frac{1}{n}\\right\\}=1,\\qquad
        \\inf\\left\\{1+\\frac{1}{n}\\right\\}=1$$

        > 滚动浏览时不应出现可见位移；公式块高度变化应被行高同步吸收。
        """
    }
}
#endif
