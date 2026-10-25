import AppKit
import ServiceManagement
import Sparkle

/// The always-available menu-bar icon. The menu is rebuilt each time it opens,
/// so checkmarks always match the current settings.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let pet: PetController
    private let updater: SPUUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    /// Friendlier names for the menu (manifest names stay the source of truth for IDs).
    private let catDescriptions = ["fluffy_b": "tan & white", "orange_c": "orange"]

    init(pet: PetController, updater: SPUUpdater) {
        self.pet = pet
        self.updater = updater
        super.init()
        statusItem.button?.image = MenuBarIcon.image
        menu.delegate = self
        menu.autoenablesItems = false // We decide which items are greyed out.
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let reason = pet.autoPauseReason, !pet.isPaused {
            let note = NSMenuItem(title: "Sleeping during \(reason)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(item(pet.isPaused ? "Wake Up" : "Go to Sleep", #selector(togglePause)))
        menu.addItem(item(pet.isHidden ? "Show Cat" : "Hide Cat", #selector(toggleHidden)))
        menu.addItem(item("Bring Cat to This Screen", #selector(bringHere)))
        menu.addItem(item("Talent Show", #selector(talentShow)))
        menu.addItem(.separator())
        addCareItems()
        menu.addItem(.separator())

        let cats = NSMenu()
        for cat in pet.manifest.cats {
            let title = catDescriptions[cat.id].map { "\(cat.name) (\($0))" } ?? cat.name
            let i = item(title, #selector(chooseCat(_:)))
            i.representedObject = cat.id
            i.state = cat.id == pet.catID ? .on : .off
            cats.addItem(i)
        }
        menu.addItem(submenu("Cat", cats))

        let sizes = NSMenu()
        for s in Settings.scales {
            let i = item("\(s)×", #selector(chooseScale(_:)))
            i.tag = s
            i.state = s == pet.settings.scale ? .on : .off
            sizes.addItem(i)
        }
        menu.addItem(submenu("Size", sizes))

        let energies = NSMenu()
        for e in Energy.allCases {
            let i = item(e.title, #selector(chooseEnergy(_:)))
            i.representedObject = e.rawValue
            i.state = e == pet.settings.energy ? .on : .off
            energies.addItem(i)
        }
        menu.addItem(submenu("Energy", energies))
        menu.addItem(submenu("Extras", extrasMenu()))
        menu.addItem(.separator())

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let update = item("Check for Updates…", #selector(checkForUpdates))
        update.isEnabled = updater.canCheckForUpdates
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(item("Quit Desktop Cat", #selector(quit)))
    }

    private func addCareItems() {
        let care = pet.care!
        let needs = care.needs
        let status = Need.allCases.map { "\($0.title) \(Int((needs[$0] * 100).rounded()))%" }.joined(separator: " · ")
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let feed = item(care.hasArt(for: .foodBowl) ? "Feed" : "Feed  — no bowl art", #selector(feed))
        feed.isEnabled = care.canPutBowlDown && care.hasArt(for: .foodBowl)
        menu.addItem(feed)

        let water = item(care.hasArt(for: .waterBowl) ? "Fill Water" : "Fill Water  — no bowl art", #selector(fillWater))
        water.isEnabled = care.canPutBowlDown && care.hasArt(for: .waterBowl)
        menu.addItem(water)

        let yarn = item(care.hasArt(for: .yarn) ? "Toss Yarn Ball" : "Toss Yarn Ball  — no yarn art", #selector(tossYarn))
        yarn.isEnabled = care.canTossYarn
        menu.addItem(yarn)
    }

    private static let extraOptions: [(String, ReferenceWritableKeyPath<Settings, Bool>, Bool)] = [
        ("Chase My Cursor", \.chaseCursor, true),
        ("Pounce at My Cursor", \.pounceAtCursor, true),
        ("Watch Videos with Me", \.watchVideos, false),
        ("Climb onto Windows", \.jumpOnWindows, true),
        ("Hang off Window Edges", \.hangOffEdges, true),
        ("Peek from Behind Windows", \.peekBehindWindows, false),
    ]
    private static let pauseOptions: [(String, ReferenceWritableKeyPath<Settings, Bool>)] = [
        ("Sleep During Full-Screen Apps", \.pauseInFullScreen),
        ("Sleep in Low Power Mode", \.pauseInLowPower),
    ]

    /// Opt-in extras (off by default) and the considerate pauses.
    private func extrasMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (index, (title, key, needsMotion)) in Self.extraOptions.enumerated() {
            let i = item(title, #selector(toggleExtra(_:)))
            i.tag = index
            i.state = pet.settings[keyPath: key] ? .on : .off
            if needsMotion && pet.reduceMotion {
                i.title += "  — off while Reduce Motion is on"
                i.isEnabled = false
            }
            sub.addItem(i)
        }
        let info = NSMenuItem(title: "Uses window positions only, no permissions", action: nil, keyEquivalent: "")
        info.isEnabled = false
        sub.addItem(info)
        sub.addItem(.separator())
        for (index, (title, key)) in Self.pauseOptions.enumerated() {
            let i = item(title, #selector(togglePauseOption(_:)))
            i.tag = index
            i.state = pet.settings[keyPath: key] ? .on : .off
            sub.addItem(i)
        }
        return sub
    }

    // MARK: - Actions

    @objc private func togglePause() { pet.setPaused(!pet.isPaused) }
    @objc private func toggleHidden() { pet.setHidden(!pet.isHidden) }
    @objc private func bringHere() { pet.bringToMouseScreen() }
    @objc private func chooseCat(_ sender: NSMenuItem) { pet.switchCat(to: sender.representedObject as? String ?? "") }
    @objc private func feed() {
        if pet.isPaused { pet.setPaused(false) }
        pet.feed()
    }
    @objc private func fillWater() {
        if pet.isPaused { pet.setPaused(false) }
        pet.fillWater()
    }
    @objc private func tossYarn() {
        if pet.isPaused { pet.setPaused(false) }
        pet.tossYarn()
    }
    @objc private func toggleExtra(_ sender: NSMenuItem) {
        let key = Self.extraOptions[sender.tag].1
        pet.setOption(key, !pet.settings[keyPath: key])
    }
    @objc private func togglePauseOption(_ sender: NSMenuItem) {
        let key = Self.pauseOptions[sender.tag].1
        pet.setOption(key, !pet.settings[keyPath: key])
    }
    @objc private func chooseEnergy(_ sender: NSMenuItem) {
        pet.setEnergy(Energy(rawValue: sender.representedObject as? String ?? "") ?? .normal)
    }
    @objc private func chooseScale(_ sender: NSMenuItem) { pet.setScale(sender.tag) }
    @objc private func talentShow() { pet.startTalentShow() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { updater.checkForUpdates() }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add Desktop Cat yourself in System Settings → General → Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Helpers

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }
}
