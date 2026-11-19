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
