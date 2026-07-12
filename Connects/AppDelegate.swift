import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = DSTheme.c.background
        NativeRendererSelfTest.installFixtureIfRequested()
        window.rootViewController = RootSplitViewController()
        window.makeKeyAndVisible()
        self.window = window
        NativeRendererSelfTest.run()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // iPad Air 1: support all orientations; layout uses Auto Layout
        return .all
    }
}
