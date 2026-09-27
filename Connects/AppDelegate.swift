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
        ConnectsPhoneReaderLandscape.supportedMask
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // iPad Air 1 can enter memory pressure while scrolling long rich chats.
        // Keep visible/persisted content intact; discard only rebuildable RAM caches.
        RenderCacheStore.trimTransientMemory()
        StudyDocumentStore.shared.trimCaches()
        StudyProgressStore.shared.trimMemory()
    }
}

/// iPhone 默认竖屏；仅 PDF/代码阅读点「翻转」后允许横屏。iPad 不受限。
enum ConnectsPhoneReaderLandscape {
    static var isActive = false

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static var supportedMask: UIInterfaceOrientationMask {
        guard isPhone else { return .all }
        return isActive ? .landscape : .portrait
    }

    static func setActive(_ active: Bool, host: UIViewController) {
        guard isPhone else { return }
        guard isActive != active else {
            requestGeometry(host: host)
            return
        }
        isActive = active
        let root = host.view.window?.rootViewController ?? host
        root.setNeedsUpdateOfSupportedInterfaceOrientations()
        host.setNeedsUpdateOfSupportedInterfaceOrientations()
        requestGeometry(host: host)
        NotificationCenter.default.post(name: .connectsPhoneReaderLandscapeDidChange, object: nil)
    }

    private static func requestGeometry(host: UIViewController) {
        guard isPhone else { return }
        let scene = host.view.window?.windowScene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let mask: UIInterfaceOrientationMask = isActive ? .landscape : .portrait
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

extension Notification.Name {
    static let connectsPhoneReaderLandscapeDidChange = Notification.Name("connectsPhoneReaderLandscapeDidChange")
}
