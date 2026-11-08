// Minimal iOS app that runs the spikes on the Simulator. Built and launched by scripts/run-ios.sh.
#if os(iOS)
import UIKit
#if !SPIKE_SINGLE_MODULE
import SpikeKit
#endif

@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

/// iOS 27 SDK requires the UIScene life cycle; the spikes start once the scene is active.
@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var started = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        let vc = UIViewController()
        vc.view.backgroundColor = .white
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !started, let ws = scene as? UIWindowScene else { return }
        started = true
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: env["SPIKE_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        let ids = (env["SPIKE_IDS"] ?? "1 2 3 4 7").split(separator: " ").compactMap { Int($0) }
        Task { @MainActor in
            let ctx = SpikeContext(outputDirectory: outDir)
            let results = await SpikeSuite.run(ids: ids, ctx: ctx)
            let platform = "iOS \(UIDevice.current.systemVersion) Simulator, \(UIDevice.current.name), screen \(ws.screen.bounds.size) @\(ws.screen.scale)x"
            let report = SpikeSuite.report(results, platform: platform)
            try? report.write(to: outDir.appendingPathComponent("results-ios.md"), atomically: true, encoding: .utf8)
            print("\n" + report)
            exit(0)
        }
    }
}

setvbuf(stdout, nil, _IONBF, 0)
_ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
#else
print("spike-ios-app runs on the iOS Simulator; see Spikes/scripts/run-ios.sh")
#endif
