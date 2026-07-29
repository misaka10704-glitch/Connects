import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UserDefaults.standard.register(defaults: ["connects_sidebar_collapsed": true])
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
        NativeRendererSelfTest.run()
        #if DEBUG
        StudyFeatureQAHarness.runIfRequested()
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
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // iPad Air 1: support all orientations; layout uses Auto Layout
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
