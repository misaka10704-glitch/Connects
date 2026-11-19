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
