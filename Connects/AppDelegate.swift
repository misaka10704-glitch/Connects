import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UserDefaults.standard.register(defaults: ["connects_sidebar_collapsed": true])
        ConnectsPaths.ensureAppFolders()
        _ = StudyWorkspaceStore.shared.ensureDefault()
        // Warm Study Markdown WKWebView (marked/KaTeX) off the critical path — chat stays Native.
        WebKitRenderWarmup.prepare()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = DSTheme.c.background
        NativeRendererSelfTest.installFixtureIfRequested()
        #if DEBUG
        ScrollStressHarness.installThinkingExpandFixtureIfRequested()
        ScrollStressHarness.installFixtureIfRequested()
        RenderAuditHarness.startIfRequested()
        #endif
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
        SettingsManager.applyIdleTimerSetting()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        SettingsManager.applyIdleTimerSetting()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Avoid keeping the screen awake while backgrounded / locked.
        application.isIdleTimerDisabled = false
        // Xcode rebuild / task switch often kills before the debounced save lands.
        ConversationStore.shared.flushPendingSave()
        WorkspaceEditSession.shared.flush()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        ConversationStore.shared.flushPendingSave()
        WorkspaceEditSession.shared.flush()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        ConversationStore.shared.flushPendingSave()
        WorkspaceEditSession.shared.flush()
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // iPhone is portrait-only; iPad keeps full rotation.
        if UIDevice.current.userInterfaceIdiom == .phone {
            return .portrait
        }
        return .all
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // iPad Air 1 can enter memory pressure while scrolling long rich chats.
        // Keep visible/persisted content intact; discard only rebuildable RAM caches.
        RenderCacheStore.trimTransientMemory()
        StudyDocumentStore.shared.trimCaches()
        StudyProgressStore.shared.trimMemory()
    }
}
