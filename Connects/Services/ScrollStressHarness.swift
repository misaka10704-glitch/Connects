import UIKit

#if DEBUG
/// Developer-only scroll stress: multi-turn fixture + automated up-scroll through Q&A pairs.
/// Launch args: `-ScrollStressFixture`, `-ScrollStressTest`, optional `-ScrollStressSlow` (iPad-like pacing).
enum ScrollStressHarness {
    private static let logTag = "[ConnectsScrollStress]"
    private static var didSchedule = false
    private static let turnCount = 20
    private static var slowMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressSlow")
    }
    private static var rotationMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScrollStressRotate")
    }

    static func installFixtureIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-ScrollStressFixture") else { return }
        let store = ConversationStore.shared
        store.updateCurrentQuietly { conversation in
            conversation.title = "滚动测试 \(turnCount)轮"
            conversation.messages.removeAll()
            for turn in 1...turnCount {
                conversation.messages.append(ChatMessage(
                    role: .user,
                    content: "问题 \(turn)：请推导方差公式、写出期望与方差的关系，并给出一个数值例子。"
                ))
                conversation.messages.append(ChatMessage(
                    role: .assistant,
                    content: assistantBody(turn: turn),
                    reasoningContent: turn.isMultiple(of: 2) ? "先展开期望，再用独立同分布假设，最后代入具体数字。" : "",
                    isStreaming: false
                ))
            }
        }
        log("installed \(turnCount)-turn fixture (persisted)")
    }

    static func scheduleIfRequested(on chat: ChatViewController) {
        guard ProcessInfo.processInfo.arguments.contains("-ScrollStressTest")
            || ProcessInfo.processInfo.arguments.contains("-ScrollStressRotate") else { return }
        guard !didSchedule else { return }
        didSchedule = true
        if ProcessInfo.processInfo.arguments.contains("-ScrollStressRotate") {
            log("scheduled rotation stress on chat VC")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                runRotation(on: chat)
            }
            return
        }
        log("scheduled on chat VC\(slowMode ? " (slow/iPad pacing)" : "")")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
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
            let settleMs: TimeInterval = slowMode ? 1.15 : 0.72
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
                DispatchQueue.main.asyncAfter(deadline: .now() + settleMs) {
                    if let anchor = anchor {
                        let expectedY = anchor.viewportY + distance
                        if let drift = chat.debugViewportDrift(row: anchor.row, expectedY: expectedY, maxAllowed: 36) {
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
            }
        }
        next()
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
}
#endif
