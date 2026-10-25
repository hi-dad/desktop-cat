import AppKit
import Sparkle

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pet: PetController?
    private var menuBar: MenuBarController?
    /// Checks GitHub about once a day for a newer version and offers to install it (Sparkle).
    private var updater: SPUStandardUpdaterController!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Menu-bar app: no Dock icon.
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherCopies()
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        let manifest: Manifest
        do {
            manifest = try Manifest.loadBundled()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Desktop Cat can't find its action list"
            alert.informativeText = "cats-and-actions.json is missing from the app bundle (\(error.localizedDescription))."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let pet = PetController(settings: Settings(), manifest: manifest)
        pet.start()
        self.pet = pet
        menuBar = MenuBarController(pet: pet, updater: updater.updater)

        // Testing aid: `open DesktopCat.app --args -demo feed|water|yarn` runs a care action
        // a moment after launch (or `hide,show`). Launch arguments aren't saved, so normal launches ignore it.
        // Extras can be chained: `-demo climb,hang,down` (turn the extra on too, e.g. `-jumpOnWindows YES`).
        if let demo = UserDefaults.standard.string(forKey: "demo") {
            var queue = demo.split(separator: ",").map(String.init)
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                guard let next = queue.first else { timer.invalidate(); return }
                switch next {
                case "feed": pet.feed()
                case "water": pet.fillWater()
                case "yarn": pet.tossYarn()
                case "talent": pet.startTalentShow()
                case "hide": // Runs off the side (once it's sitting).
                    guard pet.engine.currentID == "idle_sit" else { return }
                    pet.setHidden(true)
                case "show": // Dashes back in, once it's fully out of sight.
                    guard !pet.window.isVisible else { return }
                    pet.setHidden(false)
                case "nap": // Lies down and naps for a while (once it's sitting, after landing).
                    guard pet.engine.currentID == "idle_sit" else { return }
                    pet.brain.tuning.explicitSeconds = 30
                    pet.brain.playExplicit("sleep")
                default:
                    guard !pet.extras.isActive, pet.fallVelocity == nil else { return }
                    if !pet.extras.start(plan: next) { NSLog("DesktopCat demo: %@ not possible here", next) }
                }
                queue.removeFirst()
            }
        }
    }

    /// Only one cat at a time: a freshly built copy replaces an older running one.
    private func quitOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.processIdentifier != me {
            app.terminate()
        }
    }
}
