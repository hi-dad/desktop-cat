import AppKit

/// Ties everything together: runs the 60 fps clock, positions the window on the
/// floor of the current display, handles drag/drop, and applies settings.
final class PetController {
    let settings: Settings
    let manifest: Manifest
    let window = PetWindow()
    private(set) var engine: AnimationEngine
    private(set) var brain: Brain
    private var libraries: [String: SpriteLibrary] = [:]
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()

    // Drag / fall state
    private var mouseDownAt: CGPoint?
    private var isDragging = false
    /// Recent cursor samples while carrying, to work out how hard the cat was tossed.
    private var dragSamples: [(t: Double, p: CGPoint)] = []
    /// Downward speed while falling (nil = on the floor), and sideways speed from a toss.
    private(set) var fallVelocity: Double?
    /// Set while paused: whether the cat has settled into sleep yet (nil = not paused).
    private var restState: (asleep: Bool, toldToSleep: Bool, wentToSide: Bool, elapsed: Double)?
    private var tossVelocity: Double = 0
    private var gestures = CursorGestures()
    private var propSets: [String: PropSet] = [:]
    private(set) var care: CareController!
    private(set) var extras: ExtrasController!
    /// Bottom of the cat's window (its feet), in screen points.
    var y: Double = 0

    // Windows (positions only; see WindowScanner)
    private(set) var surface: Surface = .floor
    private(set) var windows: [WindowRect] = []
    private(set) var ledges: [Ledge] = []
    private var ridingFrame: CGRect?
    /// When the cat may leave the window it's on (it likes to stay up there a while).
    private var leaveLedgeAt = 0.0
    /// Recent sideways speeds of the window being ridden, to spot a shake.
    private var rideSpeeds: [(t: Double, vx: Double)] = []
    private var lastRideScan = 0.0
    private var lastRideMove = -10.0
    /// The window the cat was just shaken off, skipped as a landing spot until it lands.
    private var shakenOffWindow: Int?
    /// True while the window under the cat is being moved (no pouncing at the pointer dragging it).
    var ridingMovingWindow: Bool { surface != .floor && CACurrentMediaTime() - lastRideMove < 1.5 }
    /// The sprite's lean while riding a moving window (radians) and how fast it's swinging.
    private var lean = 0.0, leanSpeed = 0.0
    private var scanIn = 0.0
    private var videoCheckIn = 1.0
    private var talentShowPending = false
    private var spaceIndex: Int?
    private(set) var fullScreenActive = false
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var catID: String { settings.catID }
    var isPaused: Bool { settings.paused }
    var isHidden: Bool { settings.hidden }

    init(settings: Settings, manifest: Manifest) {
        self.settings = settings
        self.manifest = manifest
        let cat = manifest.resolveCat(settings.catID)
        settings.catID = cat.id
        let library = SpriteLibrary(cat: cat, manifest: manifest, assetRoot: SpriteLibrary.bundledAssetRoot())
        libraries[cat.id] = library
        engine = AnimationEngine(library: library)
        brain = Brain(engine: engine)
        brain.scale = Double(settings.scale)
        library.problems.forEach { NSLog("DesktopCat asset problem: %@", $0) }
        care = CareController(settings: settings, brain: brain, catWindow: window,
                              props: propSet(for: cat), scale: Double(settings.scale))
        extras = ExtrasController(pet: self)
        applyTuning()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self?.applyTuning()
        }

        window.spriteView.onMouseDown = { [weak self] e in self?.mouseDown(e) }
        window.spriteView.onMouseDragged = { [weak self] e in self?.mouseDragged(e) }
        window.spriteView.onMouseUp = { [weak self] _ in self?.mouseUp() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.savePosition()
            self?.care.save()
        }
    }

    private func propSet(for cat: CatDefinition) -> PropSet {
        if let set = propSets[cat.id] { return set }
        let folder = SpriteLibrary.bundledAssetRoot().appendingPathComponent(SpriteLibrary.folderName(cat))
        let set = PropSet.load(catFolder: folder)
        propSets[cat.id] = set
        return set
    }

    /// The floor the cat (and its props) stand on.
    var floorRect: NSRect { currentScreen().visibleFrame }

    func feed() { care.feed(floor: floorRect) }
    func fillWater() { care.fillWater(floor: floorRect) }
    func tossYarn() { care.tossYarn(floor: floorRect) }

    func start() {
        spaceIndex = SpaceTracker.index(onDisplay: currentScreen())
        applySize()
        restorePosition()
        render()
        if !settings.hidden { window.orderFrontRegardless() }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common) // Keeps running while a menu is open.
        timer = t
        // Save the position now and then, so a crash doesn't lose it.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.savePosition() }
    }

    // MARK: - Menu commands

    func setPaused(_ paused: Bool) { settings.paused = paused }

    func setHidden(_ hidden: Bool) {
        settings.hidden = hidden
        if hidden { window.orderOut(nil) } else { window.orderFrontRegardless() }
        care.setPropsVisible(!hidden)
    }

    func switchCat(to id: String) {
        guard id != catID, let cat = manifest.cat(id) else { return }
        settings.catID = id
        let library = libraries[id] ?? SpriteLibrary(cat: cat, manifest: manifest, assetRoot: SpriteLibrary.bundledAssetRoot())
        libraries[id] = library
        library.problems.forEach { NSLog("DesktopCat asset problem: %@", $0) }
        let centerX = window.frame.midX
        engine.swapLibrary(library)
        applySize(keepingCenterX: centerX)
        care.refresh(props: propSet(for: cat), scale: Double(settings.scale), floor: floorRect)
        render()
    }

    func setScale(_ scale: Int) {
        settings.scale = scale
        brain.scale = Double(settings.scale)
        applySize(keepingCenterX: window.frame.midX)
        care.refresh(props: care.props, scale: Double(settings.scale), floor: floorRect)
        render()
    }

    /// The Talent Show (from the menu): starts once the cat is on the floor.
    func startTalentShow() {
        if settings.paused { setPaused(false) }
        if settings.hidden { setHidden(false) }
        if surface != .floor || extras.isActive { extras.abort(dropping: surface != .floor) }
        talentShowPending = true
    }

    // MARK: - Desktops (Spaces)

    /// You switched desktops. The cat stayed behind on the old one, so bring it over and have it
    /// run in from the side it came from (swiping to the desktop on the right: from the left).
    private func spaceChanged() {
        let screen = currentScreen()
        let index = SpaceTracker.index(onDisplay: screen)
        defer { spaceIndex = index }
        guard !settings.hidden else { return }
        // A full-screen app is a Space of its own; the cat rests there anyway.
        guard !settings.paused, autoPauseReason == nil, !isDragging, !reduceMotion else {
            window.orderFrontRegardless()
            return
        }
        let fromLeft: Bool
        if let new = index, let old = spaceIndex, new != old {
            fromLeft = new > old
        } else {
            fromLeft = window.frame.midX < screen.frame.midX
        }
        fallVelocity = nil
        tossVelocity = 0
        surface = .floor
        ridingFrame = nil
        engine.sustainLastFrame = false
        brain.interrupt()
        updateFloor(for: screen, width: window.frame.width)
        extras.catchUp(fromLeft: fromLeft)
        placeWindowExactly()
        render()
        window.orderFrontRegardless() // Joins the desktop you're on now.
    }

    /// Move the cat to the floor of the display the mouse is on.
    func bringToMouseScreen() {
        let screen = screenContaining(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        let size = window.frame.size
        updateFloor(for: screen, width: size.width)
        brain.x = NSEvent.mouseLocation.x - size.width / 2
        extras.abort(dropping: false)
        surface = .floor
        ridingFrame = nil
        y = screen.visibleFrame.minY
        fallVelocity = nil
        tossVelocity = 0
        engine.sustainLastFrame = false
        brain.resetToIdle()
        if settings.hidden { setHidden(false) }
        placeWindow()
    }

    // MARK: - Clock

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1) // Don't jump ahead after sleep or a stall.
        lastTick = now
        guard !settings.hidden else { return }
        updateMousePassThrough()
        scanIn -= dt
        if scanIn <= 0 { scanWindows() }
        videoCheckIn -= dt
        if videoCheckIn <= 0 { checkForVideo() }
        if settings.paused || autoPauseReason != nil { windDown(dt); return }
        restState = nil
        updateLean(dt)
        care.tick(dt, floor: floorRect)
        if isDragging {
            engine.tick(dt) // Keep dangling animated while carried.
            render()
            return
        }

        if fallVelocity != nil { updateFall(dt) }
        engine.tick(dt)
        if extras.isActive {
            extras.tick(dt)
            render()
            return
        }
        if fallVelocity == nil && talentShowPending {
            talentShowPending = false
            extras.talentShow()
            render()
            return
        }
        if fallVelocity == nil {
            feedSenses()
            feedGestures(now)
            extras.maybeChase(dt: dt)
            if !extras.isActive { extras.maybePounce(dt: dt) }
            if !extras.isActive { brain.update(dt) }
        }
        placeWindow()
        render()
    }

    /// Paused (by you, Low Power Mode or a full-screen app): instead of freezing mid-action,
    /// the cat drops off any window edge, lies down and falls asleep, then stops animating.
    private func windDown(_ dt: Double) {
        if isDragging {
            engine.tick(dt)
            render()
            return
        }
        if restState == nil {
            restState = (asleep: false, toldToSleep: false, wentToSide: false, elapsed: 0)
            if extras.isActive { extras.abort(dropping: y > Double(currentScreen().visibleFrame.minY) + 1) }
        }
        guard var rest = restState, !rest.asleep else { return }
        if fallVelocity != nil { updateFall(dt) }
        engine.tick(dt)
        rest.elapsed += dt
        // In the middle of the screen: trot off to a side first, then lie down there.
        if fallVelocity == nil && !rest.wentToSide && !rest.toldToSleep {
            rest.wentToSide = true
            if surface == .floor, let side = brain.sideSpotForRest {
                brain.interrupt()
                extras.walk(to: side)
            }
        }
        if extras.isActive {
            extras.tick(dt)
            restState = rest
            render()
            return
        }
        if fallVelocity == nil {
            if ["sleep", "sleep_2"].contains(engine.currentID) {
                rest.asleep = true
            } else if !rest.toldToSleep {
                rest.toldToSleep = brain.settleForRest()
            }
        }
        if rest.elapsed > 30 { rest.asleep = true } // Never keep animating for long while resting.
        restState = rest
        placeWindow()
        render()
    }

    /// What the cat can notice without any special permission: how long since you
    /// last used the mouse or keyboard, and where the pointer is.
    private func feedSenses() {
        let anyInput = CGEventType(rawValue: ~0)!
        brain.userIdleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let f = window.frame
        let mouse = NSEvent.mouseLocation
        guard currentScreen().frame.contains(mouse) else { brain.cursorOffset = nil; return }
        let headX = f.minX + f.width * (brain.facingRight ? 0.65 : 0.35)
        let headY = f.minY + f.height * 0.7
        brain.cursorOffset = (Double(mouse.x - headX), Double(mouse.y - headY))
    }

    /// Tickle and petting detection from where the pointer is over the cat.
    private func feedGestures(_ now: Double) {
        let mouse = NSEvent.mouseLocation
        let inside = window.frame.contains(mouse)
        if let event = gestures.feed(time: now, x: Double(mouse.x), y: Double(mouse.y), inside: inside) {
            brain.react(event)
        }
    }

    func setEnergy(_ energy: Energy) {
        if settings.paused { setPaused(false) } // Picking a new energy wakes him up.
        settings.energy = energy
        applyTuning()
    }

    /// Energy level, plus Reduce Motion (no running) and the window extras' turn in the decision.
    func applyTuning() {
        var t = settings.energy.tuning
        if reduceMotion { t.chanceRun = 0 }
        brain.tuning = t
        let anyExtra = settings.jumpOnWindows || settings.hangOffEdges || settings.peekBehindWindows
        brain.exploreHook = anyExtra ? { [weak self] in self?.extras.tryStart() ?? false } : nil
    }

    /// Turn an opt-in extra or a considerate-pause option on or off.
    func setOption(_ key: ReferenceWritableKeyPath<Settings, Bool>, _ on: Bool) {
        settings[keyPath: key] = on
        if !on { extras.abort(dropping: surface != .floor) }
        applyTuning()
        scanIn = 0
    }

    /// Why the cat is resting on its own right now (nil = it isn't).
    var autoPauseReason: String? {
        if settings.pauseInLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { return "Low Power Mode" }
        if settings.pauseInFullScreen && fullScreenActive { return "a full-screen app" }
        return nil
    }

    private func render() {
        window.spriteView.show(engine.frame, facingRight: brain.facingRight, lean: lean)
    }

    // MARK: - Click-through

    /// The window ignores the mouse unless the pointer is over one of the cat's
    /// opaque pixels, so the rest of the square never blocks clicks.
    private func updateMousePassThrough() {
        if isDragging { window.ignoresMouseEvents = false; return }
        let mouse = NSEvent.mouseLocation
        let f = window.frame
        var hit = false
        if f.contains(mouse) {
            let scale = CGFloat(settings.scale)
            let sprite = engine.frame
            var px = Int((mouse.x - f.minX) / scale)
            let py = Int((f.maxY - mouse.y) / scale)
            if !brain.facingRight { px = sprite.width - 1 - px }
            hit = sprite.isOpaque(x: px, y: py)
        }
        if window.ignoresMouseEvents == hit { window.ignoresMouseEvents = !hit }
    }

    // MARK: - Drag and drop

    private func mouseDown(_ event: NSEvent) {
        mouseDownAt = NSEvent.mouseLocation
    }

    private func mouseDragged(_ event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let mouse = NSEvent.mouseLocation
        if !isDragging {
            // A few points of movement before it counts as picking the cat up, so clicks stay clicks.
            guard hypot(mouse.x - start.x, mouse.y - start.y) >= 4 else { return }
            isDragging = true
            extras.abort(dropping: false)
            surface = .floor
            ridingFrame = nil
            brain.interrupt() // Put down any bowl or ball it was busy with.
            fallVelocity = nil
            tossVelocity = 0
            dragSamples = []
            engine.request("carried", force: true) // Dangles by the scruff.
            render()
        }
        // Hold the cat by the scruff: top-centre of the sprite follows the pointer.
        let size = window.frame.size
        brain.x = mouse.x - size.width / 2
        y = mouse.y - (size.height - 5 * CGFloat(settings.scale))
        window.setFrameOrigin(NSPoint(x: brain.x, y: y))
        let now = CACurrentMediaTime()
        dragSamples.append((now, mouse))
        dragSamples.removeAll { now - $0.t > 0.1 }
    }

    private func mouseUp() {
        mouseDownAt = nil
        guard isDragging else {
            brain.poked() // A plain click.
            return
        }
        isDragging = false
        restState = nil // If paused, fall and settle back to sleep again.
        let screen = screenContaining(CGPoint(x: window.frame.midX, y: window.frame.midY))
            ?? screenContaining(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
        updateFloor(for: screen, width: window.frame.width)
        // Toss: carry the pointer's last speed into the fall (an upward flick throws it up a bit).
        var vx = 0.0, vy = 0.0
        if let first = dragSamples.first, let last = dragSamples.last, last.t - first.t > 0.01 {
            vx = Double(last.p.x - first.p.x) / (last.t - first.t)
            vy = Double(last.p.y - first.p.y) / (last.t - first.t)
        }
        tossVelocity = min(max(vx, -1500), 1500)
        let below = WindowGeometry.surface(below: y, catX: brain.x, catWidth: brain.spriteWidth, ledges: standableLedges)
        if y > (below?.y ?? Double(screen.visibleFrame.minY)) + 1 || vy > 200 {
            startFall(vy: min(max(-vy, -1000), 600))
        } else {
            land(on: screen, ledge: below)
        }
        savePosition()
    }

    private func updateFall(_ dt: Double) {
        guard var v = fallVelocity else { return }
        let floorY = Double(currentScreen().visibleFrame.minY)
        let before = y
        v += 2600 * dt // Gravity in points/s².
        y -= v * dt
        fallVelocity = v
        // Sideways drift from a toss, bouncing softly off the screen edges.
        brain.x += tossVelocity * dt
        let r = brain.floorRange
        if brain.x < r.lowerBound || brain.x > r.upperBound {
            brain.x = min(max(brain.x, r.lowerBound), r.upperBound)
            tossVelocity = -tossVelocity * 0.5
        }
        if tossVelocity != 0 { brain.facingRight = tossVelocity > 0 }
        // Land on a window top passed on the way down (when allowed), else the floor.
        let landable = standableLedges.filter { $0.windowID != shakenOffWindow }
        if v > 0, let l = WindowGeometry.surface(below: before, catX: brain.x, catWidth: brain.spriteWidth, ledges: landable),
           l.y >= y {
            land(on: currentScreen(), ledge: l)
        } else if y <= floorY {
            land(on: currentScreen(), ledge: nil)
        }
    }

    private func land(on screen: NSScreen, ledge: Ledge?) {
        fallVelocity = nil
        shakenOffWindow = nil
        tossVelocity = 0
        engine.sustainLastFrame = false
        if let l = ledge {
            y = l.y
            landed(on: .ledge(windowID: l.windowID))
        } else {
            y = screen.visibleFrame.minY
            landed(on: .floor)
        }
        brain.resetToIdle()
        engine.request("land", force: true)
        placeWindow()
    }

    // MARK: - Windows as surfaces

    /// The cat may stand on window tops when jumping or hanging is switched on.
    var canStandOnWindows: Bool { settings.jumpOnWindows || settings.hangOffEdges }
    var standableLedges: [Ledge] { canStandOnWindows ? ledges : [] }
    func ledge(_ windowID: Int) -> Ledge? {
        ledges.first { $0.windowID == windowID && $0.supports(catX: brain.x, catWidth: brain.spriteWidth) }
            ?? ledges.first { $0.windowID == windowID }
    }

    /// Height of whatever the cat is standing on.
    var surfaceY: Double {
        if case let .ledge(id) = surface, let l = ledge(id) { return l.y }
        return Double(currentScreen().visibleFrame.minY)
    }

    /// Every couple of seconds: is a video playing on this screen? Then the cat goes and watches it.
    private func checkForVideo() {
        videoCheckIn = 2
        guard settings.watchVideos else { brain.watchX = nil; return }
        let screen = currentScreen().frame
        let video = VideoWatcher.videoWindow(in: windows.isEmpty ? WindowScanner.scan() : windows)
            .flatMap { screen.intersects($0.frame) ? $0.frame : nil }
        brain.watchX = video.map { Double($0.midX) - brain.spriteWidth / 2 }
    }

    private func scanWindows() {
        let wantWindows = settings.jumpOnWindows || settings.hangOffEdges || settings.peekBehindWindows
        guard wantWindows || settings.pauseInFullScreen else {
            windows = []; ledges = []; fullScreenActive = false; scanIn = 1
            return
        }
        // Often while riding a window, so the cat moves smoothly with it.
        scanIn = !wantWindows ? 1 : surface == .floor ? 0.2 : 1.0 / 30
        let screen = currentScreen()
        windows = WindowScanner.scan()
        fullScreenActive = WindowGeometry.hasFullScreenWindow(windows, screenFrame: screen.frame)
        ledges = wantWindows ? WindowGeometry.ledges(windows: windows, screen: screen.visibleFrame, catSize: window.frame.size) : []
        extras.windowsChanged()
        followLedge()
    }

    /// Standing on a window: ride along when it moves; fall if it closes, hides or gets covered.
    private func followLedge() {
        guard case let .ledge(id) = surface, fallVelocity == nil, !isDragging else { return }
        if extras.isActive {
            // Mid-move (a pounce, a hang): carry on unless the window moves, then hold on and ride.
            guard let old = ridingFrame, let w = windows.first(where: { $0.id == id }), w.frame.origin != old.origin else { return }
            extras.abort(dropping: false)
        }
        guard canStandOnWindows, let w = windows.first(where: { $0.id == id }) else { startFall(vy: 0); return }
        let now = CACurrentMediaTime()
        if let old = ridingFrame {
            let dx = Double(w.frame.minX - old.minX)
            brain.x += dx
            brain.shiftTarget(by: dx)
            if dx != 0 || w.frame.maxY != old.maxY { lastRideMove = now }
            y += Double(w.frame.maxY - old.maxY)
            if dx != 0 || w.frame.maxY != old.maxY { feelRide(dx: dx, now: now) }
        }
        lastRideScan = now
        ridingFrame = w.frame
        if fallVelocity != nil { return } // Shaken off.
        guard let l = ledges.first(where: { $0.windowID == id && $0.supports(catX: brain.x, catWidth: brain.spriteWidth) }) else {
            startFall(vy: 0)
            return
        }
        y = l.y
        brain.floorRange = l.catRange(catWidth: brain.spriteWidth)
    }

    /// The window under the cat moved: lean against the motion, and fall off if it's being shaken.
    private func feelRide(dx: Double, now: Double) {
        let dt = max(now - lastRideScan, 1.0 / 60)
        let vx = dx / dt
        let previous = rideSpeeds.last?.vx ?? 0
        rideSpeeds.append((now, vx))
        rideSpeeds.removeAll { now - $0.t > 0.8 }
        // Speeding up tips the cat backwards (a gentle push on the lean spring).
        leanSpeed += max(-8, min(8, -(vx - previous) / 300))
        // A shake: the window whips back and forth quickly a few times.
        let fast = rideSpeeds.filter { abs($0.vx) > 900 }
        var flips = 0
        for (a, b) in zip(fast, fast.dropFirst()) where (a.vx > 0) != (b.vx > 0) { flips += 1 }
        if flips >= 3 {
            rideSpeeds = []
            if case let .ledge(id) = surface { shakenOffWindow = id } // Don't land right back on it.
            tossVelocity = max(-450, min(450, vx * 0.3))
            brain.interrupt()
            startFall(vy: -250) // Flung up a little, then down.
        }
    }

    /// The lean settles back upright like a spring.
    private func updateLean(_ dt: Double) {
        leanSpeed += (-70 * lean - 9 * leanSpeed) * dt
        lean = max(-0.25, min(0.25, lean + leanSpeed * dt))
        if surface == .floor || isDragging { lean = 0; leanSpeed = 0 }
    }

    /// Up on a window, the cat stays put a good while before thinking about coming down.
    var readyToLeaveLedge: Bool { CACurrentMediaTime() >= leaveLedgeAt }

    /// Start falling from where the cat is now (it lands on a window top or the floor).
    func startFall(vy: Double) {
        surface = .floor
        ridingFrame = nil
        updateFloor(for: currentScreen(), width: window.frame.width)
        fallVelocity = vy
        engine.request("fall", force: true)
        engine.sustainLastFrame = true // Hold the last fall frame until it lands.
    }

    /// An extra (a jump or climb) put the cat down on this surface.
    func landed(on s: Surface) {
        surface = s
        if case let .ledge(id) = s, let l = ledges.first(where: { $0.windowID == id }) {
            leaveLedgeAt = CACurrentMediaTime() + Double.random(in: 90...240)
            rideSpeeds = []
            ridingFrame = windows.first { $0.id == id }?.frame
            brain.floorRange = l.catRange(catWidth: brain.spriteWidth)
        } else {
            ridingFrame = nil
            updateFloor(for: currentScreen(), width: window.frame.width)
        }
    }

    /// Extras position the cat themselves (hanging, peeking): no clamping to the floor.
    func placeWindowExactly() {
        window.setFrameOrigin(NSPoint(x: brain.x.rounded(), y: y.rounded()))
    }

    // MARK: - Screens and position

    private func applySize(keepingCenterX centerX: CGFloat? = nil) {
        let lib = engine.library
        let scale = CGFloat(settings.scale)
        let size = NSSize(width: CGFloat(lib.frameWidth) * scale, height: CGFloat(lib.frameHeight) * scale)
        let screen = currentScreen()
        if let cx = centerX { brain.x = ScreenMath.x(keepingCenter: Double(cx), newWidth: Double(size.width)) }
        brain.spriteWidth = Double(size.width)
        window.setContentSize(size)
        window.spriteView.frame = NSRect(origin: .zero, size: size)
        if surface == .floor {
            updateFloor(for: screen, width: size.width)
            if fallVelocity == nil && !isDragging && !extras.isActive { y = screen.visibleFrame.minY }
        }
        placeWindow()
    }

    private func updateFloor(for screen: NSScreen, width: CGFloat) {
        brain.floorRange = ScreenMath.floorRange(visibleFrame: screen.visibleFrame, catWidth: Double(width))
    }

    private func placeWindow() {
        if !isDragging {
            brain.x = min(max(brain.x, brain.floorRange.lowerBound), brain.floorRange.upperBound)
        }
        window.setFrameOrigin(NSPoint(x: brain.x.rounded(), y: y.rounded()))
    }

    func currentScreen() -> NSScreen {
        let screens = NSScreen.screens
        return screens[ScreenMath.screen(for: window.frame, in: screens.map(\.frame))]
    }

    private func screenContaining(_ p: CGPoint) -> NSScreen? {
        ScreenMath.screen(containing: p, in: NSScreen.screens.map(\.frame)).map { NSScreen.screens[$0] }
    }

    private func screensChanged() {
        // A display was unplugged or rearranged: put the cat back on a real floor.
        extras.abort(dropping: false)
        surface = .floor
        ridingFrame = nil
        let screen = currentScreen()
        updateFloor(for: screen, width: window.frame.width)
        if fallVelocity == nil && !isDragging { y = screen.visibleFrame.minY }
        placeWindow()
    }

    private func savePosition() {
        let screen = currentScreen()
        let fraction = ScreenMath.fraction(of: brain.x, in: brain.floorRange)
        settings.position = SavedPosition(displayID: screen.displayID, fraction: fraction, facingRight: brain.facingRight)
    }

    private func restorePosition() {
        let saved = settings.position
        let screens = NSScreen.screens
        let screen = screens[ScreenMath.restoreScreen(savedID: saved?.displayID, attachedIDs: screens.map(\.displayID))]
        updateFloor(for: screen, width: window.frame.width)
        brain.x = ScreenMath.x(forFraction: saved?.fraction, in: brain.floorRange)
        brain.facingRight = saved?.facingRight ?? false
        y = screen.visibleFrame.minY
        placeWindow()
    }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
