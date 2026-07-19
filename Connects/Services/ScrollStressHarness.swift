import UIKit

#if DEBUG
/// Developer-only scroll stress: multi-turn fixture + automated up-scroll through Q&A pairs.
/// Launch args: `-ScrollStressFixture`, `-ScrollStressTest`, optional `-ScrollStressSlow` (iPad-like pacing).
/// Study bug path: `-ScrollStressStudyFixture -ScrollStressStudy` (narrow panel + reasoning + 卷积公式).
enum ScrollStressHarness {
    private static let logTag = "[ConnectsScrollStress]"
    private static var didSchedule = false
    private static let turnCount = 20
    private static let studyTurnCount = 10
    private static let fullChatTableWidth: CGFloat = 1024
    private static let studyPanelTableWidth: CGFloat = 408
    private static var mathHeavyMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressMathHeavy")
    }
    private static var studyMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressStudy")
    }
    private static var slowMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressSlow")
    }
    private static var rotationMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressRotate")
    }

    static func installFixtureIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("-ScrollStressStudyFixture")
            || (ProcessInfo.processInfo.arguments.contains("-ScrollStressFixture") && studyMode) {
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
            || ProcessInfo.processInfo.arguments.contains("-ScrollStressStudy") else { return }
        guard !didSchedule else { return }
        didSchedule = true
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
        log("scheduled on chat VC\(slowMode ? " (slow/iPad pacing)" : "")\(mathHeavyMode ? " (math-heavy)" : "")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            run(on: chat)
        }
    }

    private static func log(_ message: String) {
        let line = "\(logTag) \(message)\n"
        fputs(line, stderr)
        fflush(stderr)
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

    private static func runScrollSteps(on chat: ChatViewController) {
        guard let messages = ConversationStore.shared.currentConversation?.messages,
              messages.count >= turnCount * 2 - 2 else {
            log("FAIL missing fixture (need -ScrollStressFixture, \(turnCount) turns)")
            return
        }
        log("begin \(messages.count) messages, \(turnCount) turns")
        var step = 0
        let totalSteps = slowMode ? 16 : 28
        var jumpFailures = 0
        var renderFailures = 0
        var clipFailures = 0
        var chromeLateFailures = 0
        var chromeShiftFailures = 0
        // iosMath warms formulas asynchronously — allow extra settle for math-heavy fixture.
        let settleMs: TimeInterval = {
            if mathHeavyMode { return slowMode ? 2.4 : 1.6 }
            return slowMode ? 1.15 : 0.72
        }()
        let driftAllowance: CGFloat = mathHeavyMode ? 48 : 36

        func finish() {
            if jumpFailures == 0, renderFailures == 0, clipFailures == 0,
               chromeLateFailures == 0, chromeShiftFailures == 0 {
                log("PASS completed \(totalSteps) scroll steps")
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
            }
        }

        func sampleChrome(step: Int, label: String, baseline: [Int: CGFloat]?) {
            let snap = chat.debugVisibleActionChromeSnapshot()
            if label == "t+48ms" {
                if snap.missingButtons > 0 {
                    chromeLateFailures += 1
                    log("chrome-late step=\(step) missing=\(snap.missingButtons) at \(label)")
                }
            }
            if let baseline = baseline, !snap.buttonViewportY.isEmpty {
                for (row, y0) in baseline {
                    guard let y1 = snap.buttonViewportY[row] else { continue }
                    if abs(y1 - y0) > 8 {
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
            let anchor = chat.debugScrollAnchorSnapshot()
            _ = chat.debugContentOffsetY()
            let distance: CGFloat = slowMode
                ? (step.isMultiple(of: 3) ? 200 : (step.isMultiple(of: 2) ? 140 : 90))
                : (step.isMultiple(of: 3) ? 280 : (step.isMultiple(of: 2) ? 180 : 120))
            let scrollDuration: TimeInterval = slowMode ? 1.85 : 0.32
            let simulate: (@escaping () -> Void) -> Void = { done in
                if slowMode {
                    chat.debugSimulateSlowScrollUp(distance: distance, duration: scrollDuration, completion: done)
                } else {
                    chat.debugSimulateScrollUp(distance: distance, completion: done)
                }
            }
            simulate {
                let baseline = chat.debugVisibleActionChromeSnapshot().buttonViewportY
                sampleChrome(step: step, label: "t+0", baseline: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.048) {
                    sampleChrome(step: step, label: "t+48ms", baseline: nil)
                }
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
                    sampleChrome(step: step, label: "t+settle", baseline: baseline)
                    step += 1
                    next()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + settleMs) {
                    if mathHeavyMode {
                        chat.debugWaitForReadingHistoryStable(completion: checkAfterSettle)
                    } else {
                        checkAfterSettle()
                    }
                }
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
                let assistants = messages.filter { $0.role == .assistant && !$0.isStreaming }
                let fullWidth = chat.debugLayoutContentWidth()
                log("phase A full-width prewarm w=\(Int(fullWidth)) assistants=\(assistants.count)")
                AssistantMessageLayout.prewarmLayouts(
                    for: assistants,
                    targetWidth: fullWidth,
                    layoutLimit: assistants.count
                )
                chat.debugSeedCommittedHeightsFromLayoutCache()
                chat.debugPersistHeightCacheForCurrentWidth()
                chat.debugPinToBottom {
                    log("phase B enter study panel w=\(Int(studyPanelTableWidth))")
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
        let qa = chat.debugVisibleCrossQAState()
        if qa.unrenderedAssistants > 0 {
            blankFailures += 1
            log("study-blank native-missing=\(qa.unrenderedAssistants)")
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
            let totalSteps = 8
            var jumpFailures = 0
            var renderFailures = 0
            var blankFailures = priorBlankFailures
            let settleMs: TimeInterval = 0.85
            let driftAllowance: CGFloat = 52

            func finish() {
                chat.debugClearLayoutWidthOverride()
                chat.setStudyChrome(.none)
                if blankFailures == 0, jumpFailures == 0, renderFailures == 0 {
                    log("PASS study stress blank+scroll (\(totalSteps) steps)")
                } else {
                    if blankFailures > 0 { log("FAIL study blank (\(blankFailures) phases)") }
                    if jumpFailures > 0 { log("FAIL study scroll jumps \(jumpFailures)/\(totalSteps)") }
                    if renderFailures > 0 { log("FAIL study render \(renderFailures)/\(totalSteps)") }
                }
                fflush(stderr)
                exit(blankFailures == 0 && jumpFailures == 0 && renderFailures == 0 ? 0 : 1)
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
                chat.debugSimulateSlowScrollUp(distance: distance, duration: 0.55) {
                    let postScrollY = anchor.flatMap { chat.debugRowViewportY(row: $0.row) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + settleMs) {
                        chat.debugWaitForReadingHistoryStable(maxAttempts: 120) {
                            if let anchor = anchor {
                                let expectedY = postScrollY ?? (anchor.viewportY + distance)
                                if let drift = chat.debugViewportDrift(
                                    row: anchor.row,
                                    expectedY: expectedY,
                                    maxAllowed: driftAllowance
                                ) {
                                    jumpFailures += 1
                                    log("study-jump step=\(step) row=\(anchor.row) drift=\(Int(drift))pt")
                                }
                            }
                            let blank = chat.debugVisibleStudyBlankState()
                            if blank.unrenderedAssistants > 0 || blank.inflatedRows > 0 {
                                blankFailures += 1
                                log("study-blank-scroll step=\(step) unrendered=\(blank.unrenderedAssistants) inflated=\(blank.inflatedRows)")
                            }
                            let qa = chat.debugVisibleCrossQAState()
                            if qa.unrenderedAssistants > 0 || qa.missingActionButtons > 0 {
                                renderFailures += 1
                                log("study-render step=\(step) unrendered=\(qa.unrenderedAssistants) missingActions=\(qa.missingActionButtons)")
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
