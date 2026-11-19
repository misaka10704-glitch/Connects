import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = DSTheme.c.background
        window.rootViewController = RootSplitViewController()
        window.makeKeyAndVisible()
        self.window = window
        KaTeXFormulaSnapshot.shared.prepare()
        NativeRendererSelfTest.run()
        #if DEBUG
        StudyVisualQAHarness.runIfRequested()
        StudyFeatureQAHarness.runIfRequested()
        StudyAgentUXQAHarness.runIfRequested()
        StudyAgentProcessQAHarness.runIfRequested()
        StudyAgentLiveQAHarness.runIfRequested()
        StudyAgentSPIE2EHarness.runIfRequested()
        if ProcessInfo.processInfo.arguments.contains("-SettingsPreview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                (window.rootViewController as? RootSplitViewController)?.sidebarDidRequestSettings()
            }
            let scrollArg = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-ScrollBottom") || $0.hasPrefix("-ScrollMid") }
            if scrollArg != nil {
                let fraction: CGFloat = scrollArg == "-ScrollMid" ? 0.16 : 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    func scrollTo(_ view: UIView) -> Bool {
                        if let sv = view as? UIScrollView, sv.contentSize.height > sv.bounds.height {
                            let maxY = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
                            sv.setContentOffset(CGPoint(x: 0, y: max(0, maxY * fraction)), animated: false)
                            return true
                        }
                        return view.subviews.contains(where: { scrollTo($0) })
                    }
                    if let presented = window.rootViewController?.presentedViewController {
                        _ = scrollTo(presented.view)
                    }
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-BYOKPreview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let editor = BYOKProviderEditViewController(provider: nil)
                window.rootViewController?.present(editor.embeddedForSettings(onSave: {}), animated: false)
            }
        }
        // -StudyCapsuleQA: seed a demo doc + bind a conversation so the Study
        // shell opens straight into reader mode (stage-capsule screenshots).
        // Optional "-CapsuleDarkPage" flips the per-reader ☀/☾ override.
        if ProcessInfo.processInfo.arguments.contains("-StudyCapsuleQA") {
            if ProcessInfo.processInfo.arguments.contains("-CapsuleDarkPage") {
                ReaderThemeManager.shared.override = .dark
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("CapsuleQA", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("总结.md")
                let md = """
                # 工作区总结

                ## 一、总览

                本工作区是一个 **算法练习 + 概率论笔记** 的集合，大致分四类：

                | 类别 | 文件 | 说明 |
                |------|------|------|
                | 概率论笔记 | `总结.md` | 弱大数定律的表述、切比雪夫证明 |
                | 排序 | `bubblesort.cpp` | 冒泡排序 |
                | 字符串匹配 | `kmp.c`、`kmp` | KMP 算法（源码 + 可执行文件） |
                | 字符串匹配 | `least_char_search.c` | 最小/最少字符查找 |

                ## 二、概率论

                设 $X_1, X_2, \\ldots$ 独立同分布，$E[X_i] = \\mu$，则

                $$ \\bar{X}_n = \\frac{1}{n}\\sum_{i=1}^{n} X_i \\xrightarrow{P} \\mu $$

                这是弱大数定律的核心表述。正文段落填充若干文字用于观察底部
                浮动控件对文档内容的遮挡情况，多写几行让页面更长一点。
                """
                try? md.write(to: file, atomically: true, encoding: .utf8)
                if let doc = try? StudyDocumentStore.shared.openDocument(from: file, forceText: false) {
                    _ = ConversationStore.shared.createConversation(studyDocumentID: doc.id)
                }
                if ProcessInfo.processInfo.arguments.contains("-CapsuleHalfStage") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        (window.rootViewController as? RootSplitViewController)?
                            .qaStudyShell.qaSetPanelStage(.half)
                    }
                }
            }
        }
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        SettingsManager.applyIdleTimerSetting()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Avoid keeping the screen awake while backgrounded / locked.
        UIApplication.shared.isIdleTimerDisabled = false
        // Xcode rebuild / task switch often kills before the debounced save lands.
        ConversationStore.shared.flushPendingSave()
        WorkspaceEditSession.shared.flush()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        ConversationStore.shared.flushPendingSave()
        WorkspaceEditSession.shared.flush()
    }
}
