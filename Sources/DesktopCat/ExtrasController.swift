import AppKit

/// The extras: climbing onto windows (from behind them), hanging off an edge, peeking
/// from behind a window, chasing the cursor and pouncing at it. Each one is a short
/// script of steps; while a script runs it drives the cat, then hands back to the Brain.
final class ExtrasController {
    unowned let pet: PetController

    enum Step {
        case walk(toX: Double, run: Bool)
        case face(right: Bool)
        case leap(toX: Double, toY: Double, onto: Surface)
        case climb(toY: Double)
        case place(x: Double, y: Double)
        case start(String)                 // begin an action, don't wait
        case play(String, seconds: Double) // begin an action and wait
        case wait(Double)
        case slide(toY: Double, seconds: Double)
        case hideBehind(windowID: Int)
        case comeForward
        case emergeAbove(y: Double)        // come out from behind once the feet clear this height
        case drop
        case chase
        case stalk(seconds: Double, atPointer: Bool) // a play bow (front down, rear up), eyes on the pointer
        case pounceAtAim                   // leap in an arc to where the pointer is
        case pounceAt(x: Double)           // the same leap, to a set spot
        case playOnce(String)              // play an action through to its end
        case tossYarn                      // the show's finale: a yarn ball to chase
        case watchForPlay(seconds: Double) // after a pounce: sit and see if you play back
        case dash(toX: Double)             // a quick run, going out of sight or coming back
    }

    private var steps: [Step] = []
    private var current: Step?
    private var t = 0.0
    private var from = (x: 0.0, y: 0.0)
    private var leap: (vx: Double, vy0: Double, duration: Double, prep: Double)?
    private var pounceDir = 1.0
    /// The window the cat is hiding behind or climbing, if any (abort if it goes away).
    private var involvedWindow: Int?
    private var hidden = false
    private var emergeY: Double?
    private var pounceAim = 0.0
    private var bowHeld = false

    // Cursor chase bookkeeping
    private var lastMouse = CGPoint.zero
    private var lastMouseMoved = 0.0
    private var clock = 0.0
    private var chaseCooldown = 0.0
    private var chaseStarted = 0.0
    private var pounceCooldown = 3.0
    private var cursorNearFor = 0.0
    /// Where the pointer was at the last pounce. A pointer left there is "caught": no more
    /// pounces until it moves well away.
    private var pouncedAt: CGPoint?
    private var watchStarted = 0.0
    private var dashSpeed = 0.0
    /// When he last started a game on his own (a chase or pounce you didn't invite).
    private var selfStarts: [TimeInterval] = []
    private var lowAndMovingFor = 0.0

    /// He starts at most 2 games of his own every 5 minutes (Calm: 1 every 10). Once you play back,
    /// the game isn't capped (except in Calm, where one pounce is enough).
    private var calm: Bool { pet.settings.energy == .calm }
    private var mayStartOnHisOwn: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        selfStarts.removeAll { now - $0 > (calm ? 600 : 300) }
        return selfStarts.count < (calm ? 1 : 2)
    }
    private func noteSelfStart() { selfStarts.append(ProcessInfo.processInfo.systemUptime) }

    static let gravity = 2600.0

    init(pet: PetController) { self.pet = pet }

    var isActive: Bool { current != nil }
    private var brain: Brain { pet.brain }
    private var engine: AnimationEngine { pet.engine }
    private var scale: Double { Double(pet.settings.scale) }
    private var catW: Double { brain.spriteWidth }
    private var catH: Double { Double(pet.window.frame.height) }
    private var frameH: Double { Double(engine.library.frameHeight) }
    private var motionAllowed: Bool { !pet.reduceMotion }

    // MARK: - Choosing an adventure (called from the Brain when it decides what to do)

    func tryStart() -> Bool {
        let onLedge = pet.surface != .floor
        var plans: [() -> [Step]?] = []
        if pet.settings.jumpOnWindows && motionAllowed {
            if onLedge {
                if pet.readyToLeaveLedge { plans.append { self.planGetDown() } }
            } else {
                // Scratching at a window's side is a favourite; so is getting up on top of one.
                if (pet.settings.jumpOnWindows || pet.settings.peekBehindWindows) && Double.random(in: 0..<1) < 0.4,
                   let s = planBatEdge() { run(s); return true }
                if Double.random(in: 0..<1) < 0.75, let s = planClimbUp() { run(s); return true }
                plans.append(planClimbUp)
            }
        }
        if pet.settings.hangOffEdges && motionAllowed { plans.append(planHang) }
        if (pet.settings.jumpOnWindows || pet.settings.peekBehindWindows) && !onLedge { plans.append { self.planBatEdge() } }
        if pet.settings.peekBehindWindows { plans.append(planPeek) }
        for plan in plans.shuffled() {
            if let s = plan() { run(s); return true }
        }
        return false
    }

    /// Testing aid: start one named extra right now ("climb", "down", "back", "hang", "peek").
    func start(plan name: String) -> Bool {
        let plans: [String: () -> [Step]?] = ["climb": planClimbUp, "down": { self.planGetDown() }, "back": { self.planGetDown(back: true) },
                                              "hang": planHang, "peek": planPeek, "bat": { self.planBatEdge() },
                                              "batfront": { self.planBatEdge(front: true) }, "batback": { self.planBatEdge(front: false) }]
        guard !isActive, let plan = plans[name], let s = plan() else { return false }
        run(s)
        return true
    }

    /// Pounces at the pointer when it lingers close by at the cat's level.
    func maybePounce(dt: Double) {
        pounceCooldown -= dt
        let mouse = NSEvent.mouseLocation
        let centerX = brain.x + catW / 2
        let dx = Double(mouse.x) - centerX
        // Not while you're holding the mouse button (dragging a window, selecting text).
        let near = pet.settings.pounceAtCursor && motionAllowed && !isActive && !userBusy && pouncedAt == nil &&
            NSEvent.pressedMouseButtons == 0 && !pet.ridingMovingWindow &&
            brain.bowl == nil && brain.yarn == nil &&
            ["idle_sit", "walk", "blink", "look_up", "look_down", "sit_back"].contains(engine.currentID) &&
            !pet.window.frame.contains(mouse) &&
            abs(dx) > catW * 0.45 && abs(dx) < catW * 2.2 &&
            Double(mouse.y) > pet.y - catH * 0.2 && Double(mouse.y) < pet.y + catH * 1.1
        cursorNearFor = near ? cursorNearFor + dt : 0
        // Watch it for a moment first (it's stalking), then go for it.
        guard near, pounceCooldown <= 0, cursorNearFor > 0.6, mayStartOnHisOwn else { return }
        noteSelfStart()
        pounceCooldown = Double.random(in: 6...14)
        cursorNearFor = 0
        pounceDir = dx > 0 ? 1 : -1
        brain.facingRight = pounceDir > 0
        run([.stalk(seconds: Double.random(in: 1.2...1.7), atPointer: true), .pounceAtAim, .watchForPlay(seconds: 3)])
    }

    /// You're working, not playing: typed in the last few seconds or just clicked.
    /// (Same no-permission timers the cat uses to notice you've gone away.)
    private var userBusy: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 3 ||
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown) < 5
    }

    private func trackMouse(_ dt: Double) {
        clock += dt
        let mouse = NSEvent.mouseLocation
        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 2 { lastMouseMoved = clock }
        lastMouse = mouse
        if let p = pouncedAt, hypot(mouse.x - p.x, mouse.y - p.y) > catW * 1.5 { pouncedAt = nil }
    }

    /// Chasing starts on its own when the pointer is moving near the cat's level.
    func maybeChase(dt: Double) {
        trackMouse(dt)
        chaseCooldown -= dt
        let mouse = NSEvent.mouseLocation
        let tempting = pet.settings.chaseCursor && motionAllowed && !isActive && chaseCooldown <= 0 && !userBusy &&
              NSEvent.pressedMouseButtons == 0 && !pet.ridingMovingWindow &&
              brain.bowl == nil && brain.yarn == nil &&
              ["idle_sit", "walk", "run", "blink", "look_up", "look_down", "sit_back"].contains(engine.currentID) &&
              clock - lastMouseMoved < 0.3 &&
              pet.currentScreen().frame.contains(mouse) && !pet.window.frame.contains(mouse) &&
              Double(mouse.y) < pet.y + catH * 3 &&
              abs(Double(mouse.x) - (brain.x + catW / 2)) > catW * 0.8
        // A quick trip down to click something isn't play: the pointer has to hang about low for a second.
        lowAndMovingFor = tempting ? lowAndMovingFor + dt : 0
        guard lowAndMovingFor >= 1, mayStartOnHisOwn else { return }
        lowAndMovingFor = 0
        noteSelfStart()
        chaseStarted = clock
        run([.chase])
    }

    private func run(_ s: [Step]) {
        steps = s
        brain.pauseForExtras()
        next()
    }

    // MARK: - Plans

    private var surfaceY: Double { pet.surfaceY }
    private var screen: CGRect { pet.currentScreen().visibleFrame }
    private var maxJump: Double { catH * 1.6 }

    private func coveredInFront(of id: Int, _ rect: CGRect) -> Bool {
        WindowGeometry.coveredInFront(of: id, rect, windows: pet.windows)
    }

    /// The floor between two cat positions, a cat high.
    private func floorStrip(_ a: Double, _ b: Double) -> CGRect {
        CGRect(x: min(a, b), y: Double(screen.minY), width: abs(b - a) + catW, height: catH)
    }

    /// Just under and over a window's top edge, where the cat peeks out.
    private func peekStrip(x: Double, top: CGFloat) -> CGRect {
        CGRect(x: x, y: Double(top) - catH, width: catW, height: catH * 2)
    }

    /// Up onto a window from behind it: slip round the side and behind it, peek over the top,
    /// duck back down, then spring up from behind and land on top.
    private func planClimbUp() -> [Step]? {
        guard pet.surface == .floor else { return nil }
        let floorY = Double(screen.minY)
        for w in pet.windows.shuffled() {
            let f = w.frame
            // Its bottom must be near the floor, so the cat is out of sight while it's behind.
            guard Double(f.minY) <= floorY + catH * 0.5, Double(f.maxY) - floorY >= catH * 1.3 else { continue }
            guard let top = pet.ledges.filter({ $0.windowID == w.id && $0.width >= catW * 1.4 }).randomElement(),
                  let sideX = sideOutside(f) else { continue }
            let lo = max(top.minX, Double(f.minX)) + catW * 0.2, hi = min(top.maxX, Double(f.maxX)) - catW * 1.2
            guard lo <= hi else { continue }
            let x = Double.random(in: lo...hi)
            guard !coveredInFront(of: w.id, floorStrip(sideX, x)), !coveredInFront(of: w.id, peekStrip(x: x, top: f.maxY)) else { continue }
            let hiddenY = Double(f.maxY) - frameH * scale - 2 * scale
            let range = top.catRange(catWidth: catW)
            let landing = min(max(x + (Bool.random() ? 1 : -1) * catW * 0.3, range.lowerBound), range.upperBound)
            involvedWindow = w.id
            // Out of sight, climbing a taller window takes longer.
            let climbTime = min(4, (Double(f.maxY) - floorY) / (90 * scale))
            return [.walk(toX: sideX, run: false), .hideBehind(windowID: w.id), .walk(toX: x, run: false),
                    .wait(climbTime), .place(x: x, y: hiddenY), .start("peek"), .slide(toY: Double(f.maxY) - scale, seconds: 0.4),
                    .wait(Double.random(in: 1.5...3)), .slide(toY: hiddenY, seconds: 0.25), .wait(0.3),
                    .emergeAbove(y: top.y), .leap(toX: landing, toY: top.y, onto: .ledge(windowID: w.id))]
        }
        return nil
    }

    /// Down from a window: hop off one end, or now and then hop down the back and stroll out from behind.
    private func planGetDown(back: Bool? = nil) -> [Step]? {
        guard case let .ledge(id) = pet.surface, let l = pet.ledge(id) else { return nil }
        let floorY = Double(screen.minY)
        if back ?? (Double.random(in: 0..<1) < 0.4), let f = pet.windows.first(where: { $0.id == id })?.frame,
           Double(f.minY) <= floorY + catH * 0.5, let outX = sideOutside(f) {
            let range = l.catRange(catWidth: catW)
            let lo = max(range.lowerBound, Double(f.minX)), hi = min(range.upperBound, Double(f.maxX) - catW)
            if lo <= hi, !coveredInFront(of: id, floorStrip(min(max(brain.x, lo), hi), outX)) {
                let x = min(max(brain.x, lo), hi)
                involvedWindow = id
                return [.hideBehind(windowID: id), .leap(toX: x, toY: floorY, onto: .floor),
                        .walk(toX: outX, run: false), .comeForward]
            }
        }
        // Off the end of the ledge, onto a lower window or the floor.
        let right = Bool.random()
        let range = l.catRange(catWidth: catW)
        let edge = right ? range.upperBound : range.lowerBound
        let landingX = right ? l.maxX + 4 * scale : l.minX - catW - 4 * scale
        guard landingX >= Double(screen.minX), landingX + catW <= Double(screen.maxX) else { return nil }
        let below = pet.standableLedges.filter { $0.y < l.y - 1 && $0.supports(catX: landingX, catWidth: catW) }.max { $0.y < $1.y }
        return [.walk(toX: edge, run: false), .face(right: right),
                .leap(toX: landingX, toY: below?.y ?? floorY, onto: below.map { .ledge(windowID: $0.windowID) } ?? .floor)]
    }

    /// Where the cat can stand just beside a window (the nearer side that fits on screen).
    private func sideOutside(_ f: CGRect) -> Double? {
        let left = Double(f.minX) - catW - 2, right = Double(f.maxX) + 2
        let floor = ScreenMath.floorRange(visibleFrame: screen, catWidth: catW) // The real floor, even from up on a window.
        let fitsLeft = left >= floor.lowerBound, fitsRight = right <= floor.upperBound
        let centre = brain.x + catW / 2
        let preferLeft = centre - Double(f.minX) < Double(f.maxX) - centre
        if fitsLeft && (preferLeft || !fitsRight) { return left }
        return fitsRight ? right : nil
    }

    private func planHang() -> [Step]? {
        guard case let .ledge(id) = pet.surface, let l = pet.ledge(id),
              let hangFrame = engine.library.action("hang_edge")?.frames.first else { return nil }
        let right = Bool.random()
        let range = l.catRange(catWidth: catW)
        let pawTop = Double(hangFrame.opaqueBounds.minY)
        // Hang from the corner: centre just inside the end, paws gripping the top edge.
        let center = right ? l.maxX - 3 * scale : l.minX + 3 * scale
        let hangY = l.y + 2 * scale - (frameH - pawTop) * scale
        guard hangY > Double(screen.minY) else { return nil }
        var s: [Step] = [.walk(toX: right ? range.upperBound : range.lowerBound, run: false), .face(right: right),
                         .place(x: center - catW / 2, y: hangY), .play("hang_edge", seconds: Double.random(in: 3...6))]
        if !pet.readyToLeaveLedge || Bool.random() {
            s.append(.leap(toX: right ? range.upperBound - catW * 0.3 : range.lowerBound + catW * 0.3, toY: l.y, onto: .ledge(windowID: id)))
        } else {
            s.append(.drop)
        }
        involvedWindow = id
        return s
    }

    private func planPeek() -> [Step]? {
        guard pet.surface == .floor else { return nil }
        let floorY = Double(screen.minY)
        for w in pet.windows.shuffled() {
            let f = w.frame
            guard Double(f.minY) <= floorY + catH * 0.5, Double(f.maxY) - floorY >= catH * 1.3,
                  Double(f.maxY) + catH <= Double(screen.maxY) else { continue }
            // A visible stretch of its top edge, wide enough, that the cat can get under.
            let tops = pet.ledges.filter { $0.windowID == w.id && $0.width >= catW * 1.4 }
            guard let top = tops.randomElement() else { continue }
            let lo = max(top.minX, Double(f.minX)) + catW * 0.2, hi = min(top.maxX, Double(f.maxX)) - catW * 1.2
            guard lo <= hi else { continue }
            let x = Double.random(in: lo...hi)
            let hiddenY = Double(f.maxY) - frameH * scale - 2 * scale
            let peekY = Double(f.maxY) - scale
            // Out the nearer side afterwards.
            let outLeft = x - Double(f.minX) < Double(f.maxX) - x
            let outX = outLeft ? Double(f.minX) - catW - 2 : Double(f.maxX) + 2
            guard outX >= Double(screen.minX), outX + catW <= Double(screen.maxX),
                  !coveredInFront(of: w.id, floorStrip(x, outX)), !coveredInFront(of: w.id, peekStrip(x: x, top: f.maxY)) else { continue }
            involvedWindow = w.id
            return [.walk(toX: x, run: false), .hideBehind(windowID: w.id), .place(x: x, y: hiddenY),
                    .start("peek"), .slide(toY: peekY, seconds: 0.4), .wait(Double.random(in: 3...5)),
                    .slide(toY: hiddenY, seconds: 0.4), .place(x: x, y: floorY),
                    .walk(toX: outX, run: false), .comeForward]
        }
        return nil
    }

    private func beginPounce(at x: Double) {
        let reach = catW * 2.5 // No farther than a good leap.
        pounceAim = clampToSurface(min(max(x, brain.x - reach), brain.x + reach))
        pounceDir = pounceAim >= brain.x ? 1 : -1
        brain.facingRight = pounceDir > 0
        engine.request("pounce", force: true)
        engine.freeze(for: 0.06)
    }

    /// Bat at a window's side edge: standing beside it in front, or poking a paw out from behind it.
    private func planBatEdge(front: Bool? = nil) -> [Step]? {
        guard pet.surface == .floor, let paw = engine.library.action("play_paw"), paw.hasRealArt else { return nil }
        let floorY = Double(screen.minY)
        let reach = Double(paw.frames.map { $0.opaqueBounds.maxX }.max() ?? 40) // paw tip, in sprite pixels
        let w = Double(engine.library.frameWidth)
        let floor = ScreenMath.floorRange(visibleFrame: screen, catWidth: catW)
        for win in pet.windows.shuffled() {
            let f = win.frame
            // An edge at the cat's height: the window comes down to (near) the floor and is tall enough.
            guard Double(f.minY) <= floorY + catH * 0.3, Double(f.maxY) - floorY >= catH * 0.8,
                  f.width >= catW * 2 else { continue }
            let leftEdge = Bool.random()
            let edge = Double(leftEdge ? f.minX : f.maxX)
            let bats: [Step] = Array(repeating: .playOnce("play_paw"), count: Int.random(in: 3...4))
            if front ?? Bool.random() {
                // In front, beside the edge, paw just touching it.
                let x = leftEdge ? edge + scale - (reach + 1) * scale : edge - scale - (w - 1 - reach) * scale
                guard x >= floor.lowerBound, x <= floor.upperBound else { continue }
                return [.walk(toX: x, run: false), .face(right: leftEdge)] + bats + [.play("idle_sit", seconds: 0.5)]
            }
            // From behind: tucked behind the window by its edge, a paw poking out past it.
            let outside = leftEdge ? edge - catW - 2 : edge + 2
            guard outside >= floor.lowerBound, outside <= floor.upperBound else { continue }
            let poke = catW * 0.33 // Head and paw peek out past the edge.
            let x = leftEdge ? edge - poke - (w - 1 - reach) * scale : edge + poke - (reach + 1) * scale
            guard !coveredInFront(of: win.id, floorStrip(outside, x)) else { continue }
            involvedWindow = win.id
            return [.walk(toX: outside, run: false), .hideBehind(windowID: win.id), .walk(toX: x, run: false),
                    .face(right: !leftEdge)] + bats + [.walk(toX: outside, run: false), .comeForward]
        }
        return nil
    }

    /// You switched to another desktop: the cat was left behind, so it dashes in from the side it came from.
    func catchUp(fromLeft: Bool) {
        abort(dropping: false)
        let floor = ScreenMath.floorRange(visibleFrame: screen, catWidth: catW)
        let start = fromLeft ? Double(screen.minX) - catW : Double(screen.maxX)
        let span = floor.upperBound - floor.lowerBound
        let stop = fromLeft ? floor.lowerBound + span * Double.random(in: 0.15...0.35)
                            : floor.upperBound - span * Double.random(in: 0.15...0.35)
        pet.edgeClip = pet.currentScreen().frame // Not seen on the next display while it's off the edge.
        run([.place(x: start, y: Double(screen.minY)), .face(right: fromLeft), .walk(toX: stop, run: true),
             .play("idle_sit", seconds: 0.3)])
    }

    /// Hide: dash off the nearer side of the screen (from a window top, hop down first).
    /// Returns which side it went, or nil if it can't right now (then it just vanishes).
    func runOff() -> (left: Bool, Void)? {
        if isActive {
            guard pet.surface == .floor else { return nil }
            abort(dropping: false)
        }
        let frame = pet.currentScreen().frame
        let left = brain.x + catW / 2 < Double(frame.midX)
        var s: [Step] = []
        if pet.surface != .floor {
            guard let down = planGetDown(back: false), case let .leap(_, _, onto)? = down.last, onto == .floor else { return nil }
            s = down
        }
        s += [.dash(toX: left ? Double(frame.minX) - catW - 2 : Double(frame.maxX) + 2)]
        pet.edgeClip = frame
        run(s)
        return (left, ())
    }

    /// Show again: dash in from that side and leap the last bit.
    func comeBack(fromLeft: Bool) {
        abort(dropping: false)
        let frame = pet.currentScreen().frame
        let floor = ScreenMath.floorRange(visibleFrame: screen, catWidth: catW)
        let span = floor.upperBound - floor.lowerBound
        let stop = fromLeft ? floor.lowerBound + span * Double.random(in: 0.12...0.25)
                            : floor.upperBound - span * Double.random(in: 0.12...0.25)
        let start = fromLeft ? Double(frame.minX) - catW - 2 : Double(frame.maxX) + 2
        let takeOff = fromLeft ? max(stop - catW * 2.2, Double(frame.minX)) : min(stop + catW * 2.2, Double(frame.maxX) - catW)
        pet.edgeClip = frame
        run([.place(x: start, y: Double(screen.minY)), .face(right: fromLeft), .dash(toX: takeOff),
             .pounceAt(x: stop), .play("idle_sit", seconds: 0.4)])
    }

    /// Head somewhere on the floor (used to wander off to a side before resting).
    func walk(to x: Double) {
        let far = abs(x - brain.x) > catW * 2.5 // Trot rather than stroll when it's a way off.
        run([.walk(toX: x, run: far)])
    }

    /// The Talent Show: about half a minute of the cat's best tricks, for showing it off.
    func talentShow() {
        abort(dropping: false)
        let floor = ScreenMath.floorRange(visibleFrame: screen, catWidth: catW)
        let span = floor.upperBound - floor.lowerBound
        let mid = brain.x + catW / 2 < Double(screen.midX)
        // Work across the screen and back, starting on whichever side has more room.
        let a = floor.lowerBound + span * (mid ? 0.3 : 0.7), b = floor.lowerBound + span * (mid ? 0.7 : 0.3)
        let dirAB: Double = b > a ? 1 : -1
        var s: [Step] = [.playOnce("happy"), .walk(toX: a, run: true), .face(right: dirAB > 0),
                         .stalk(seconds: 1.0, atPointer: false), .pounceAt(x: a + dirAB * catW * 2),
                         .playOnce("roll_over"), .wait(0.6), .playOnce("play_paw"), .playOnce("play_paw"),
                         .walk(toX: b, run: true), .face(right: dirAB < 0)]
        let floorY = Double(screen.minY)
        s += [.leap(toX: b - dirAB * catW * 0.6, toY: floorY, onto: .floor),
              .leap(toX: b - dirAB * catW * 1.2, toY: floorY, onto: .floor),
              .playOnce("stretch"), .playOnce("groom"), .playOnce("groom"),
              .stalk(seconds: 0.9, atPointer: false), .pounceAt(x: b - dirAB * catW * 3.2),
              .playOnce("wave"), .playOnce("happy"), .play("idle_sit", seconds: 0.6)]
        if pet.care.canTossYarn && pet.care.hasArt(for: .yarn) { s.append(.tossYarn) }
        run(s)
    }

    private func clampToSurface(_ x: Double) -> Double {
        min(max(x, brain.floorRange.lowerBound), brain.floorRange.upperBound)
    }

    // MARK: - Running steps

    func tick(_ dt: Double) {
        guard let step = current else { return }
        t += dt
        trackMouse(dt) // keep the chase clock running through stalks and pounces too
        if update(step, dt) { next() }
        if let e = emergeY, hidden, pet.y > e + 1 { emergeY = nil; restoreLevel() }
        pet.placeWindowExactly()
    }

    private func next() {
        guard !steps.isEmpty else { finish(); return }
        let step = steps.removeFirst()
        current = step
        t = 0
        from = (brain.x, pet.y)
        begin(step)
    }

    private func begin(_ step: Step) {
        switch step {
        case let .walk(toX, run):
            if abs(toX - brain.x) > 1 {
                brain.facingRight = toX > brain.x
                engine.request(run ? "run" : "walk", force: true)
            }
        case let .face(right):
            brain.facingRight = right
        case let .leap(toX, toY, _):
            let apex = max(from.y, toY) + 25 * scale
            let g = Self.gravity
            let vy0 = (2 * g * (apex - from.y)).squareRoot()
            let duration = vy0 / g + (2 * (apex - toY) / g).squareRoot()
            let vx = (toX - from.x) / max(duration, 0.01)
            if abs(vx) > 1 { brain.facingRight = vx > 0 }
            leap = (vx, vy0, duration, 0.2)
            engine.request("jump", force: true) // First frame is the crouch.
            engine.freeze(for: 0.2)
            engine.sustainLastFrame = true
        case .climb:
            engine.request("climb", force: true)
        case let .place(x, y):
            brain.x = x
            pet.y = y
        case let .start(id):
            engine.request(id, force: true)
        case let .play(id, _):
            engine.request(id, force: true)
        case .wait, .slide:
            break
        case let .hideBehind(id):
            // Drop to normal window level and tuck in just below that window.
            pet.window.level = .normal
            pet.window.order(.below, relativeTo: id)
            hidden = true
        case .comeForward:
            restoreLevel()
        case let .emergeAbove(y):
            emergeY = y
        case .drop:
            pet.startFall(vy: 0)
        case .chase:
            engine.request("chase", force: true) // chase reuses run's frames
        case .stalk:
            engine.request("stretch", force: true) // Its opening is a play bow; we hold the second frame.
            bowHeld = false
        case .pounceAtAim:
            pouncedAt = NSEvent.mouseLocation
            beginPounce(at: Double(NSEvent.mouseLocation.x) - catW / 2) // Where the pointer is now.
        case let .pounceAt(x):
            beginPounce(at: x)
        case let .playOnce(id):
            engine.request(id, force: true)
        case .tossYarn:
            pet.tossYarn()
        case let .dash(toX):
            brain.facingRight = toX > brain.x
            engine.request("run", force: true)
            // Quick, but never more than a couple of seconds however far it is.
            dashSpeed = max(brain.tuning.runSpeed * scale * 1.8, abs(toX - brain.x) / 2.2)
        case .watchForPlay:
            watchStarted = clock
            engine.request("idle_sit", force: true)
        }
    }

    /// Returns true when the step is done.
    private func update(_ step: Step, _ dt: Double) -> Bool {
        switch step {
        case let .walk(toX, run):
            let speed = (run ? brain.tuning.runSpeed : brain.tuning.walkSpeed) * scale
            return move(toward: toX, speed: speed, dt: dt)
        case .face, .place, .start, .hideBehind, .comeForward, .emergeAbove:
            return true
        case let .leap(toX, toY, onto):
            guard let l = leap else { return true }
            let tt = t - l.prep
            if tt <= 0 { return false }
            if tt < l.duration {
                brain.x = from.x + l.vx * tt
                pet.y = from.y + l.vy0 * tt - Self.gravity * tt * tt / 2
                return false
            }
            if engine.currentID == "jump" {
                brain.x = toX
                pet.y = toY
                engine.sustainLastFrame = false
                pet.landed(on: onto)
                engine.request("land", force: true)
            }
            return engine.currentID != "land"
        case let .climb(toY):
            pet.y = min(toY, pet.y + 30 * scale * dt)
            return pet.y >= toY
        case let .play(_, seconds):
            return t >= seconds
        case let .wait(seconds):
            return t >= seconds
        case let .slide(toY, seconds):
            let k = min(1, t / seconds)
            pet.y = from.y + (toY - from.y) * k
            return k >= 1
        case .drop:
            return true
        case .chase:
            return updateChase(dt)
        case let .stalk(seconds, atPointer):
            if atPointer {
                let mouse = NSEvent.mouseLocation
                let dx = Double(mouse.x) - (brain.x + catW / 2)
                // Lost it (moved far away or up out of reach): stand back up.
                if abs(dx) > catW * 3.2 || Double(mouse.y) > pet.y + catH * 1.6 || NSEvent.pressedMouseButtons != 0 || userBusy {
                    if case .pounceAtAim = steps.first { steps.removeFirst() }
                    if steps.isEmpty { steps = [.play("idle_sit", seconds: 0.4)] }
                    return true
                }
                brain.facingRight = dx > 0
            }
            // Bow down into the stretch's first frames, then hold the bow (rear up) until it's time.
            if t >= FrameTiming.secondsPerFrame("stretch") * 1.1 && !bowHeld {
                bowHeld = true
                engine.freeze(for: 60)
            }
            return t >= seconds
        case let .playOnce(id):
            return (engine.currentID != id && t > 0.05) || t > 6
        case .tossYarn:
            return true
        case let .dash(toX):
            return move(toward: toX, speed: dashSpeed, dt: dt)
        case let .watchForPlay(seconds):
            let mouse = NSEvent.mouseLocation
            let nearby = abs(Double(mouse.x) - (brain.x + catW / 2)) < catW * 4 && Double(mouse.y) < pet.y + catH * 3
            if lastMouseMoved > watchStarted && nearby && !userBusy && !calm {
                // You moved the pointer near him again: you're playing. Game on.
                steps = pet.settings.chaseCursor ? [.chase] : []
                return true
            }
            if t >= seconds || userBusy || calm {
                // You didn't: he loses interest, has a wash, and leaves the pointer alone for a while.
                steps = [.playOnce("groom")]
                chaseCooldown = Double.random(in: 45...90)
                pounceCooldown = chaseCooldown
                return true
            }
            return false
        case .pounceAtAim, .pounceAt:
            // Frame 1 (crouch) shows briefly, frames 2-4 are the leap: move in an arc during those.
            let airStart = 0.06 + FrameTiming.secondsPerFrame("pounce"), air = 3 * FrameTiming.secondsPerFrame("pounce")
            let k = min(1, max(0, (t - airStart) / air))
            if engine.currentID == "pounce" || k < 1 {
                brain.x = from.x + (pounceAim - from.x) * k
                pet.y = from.y + catH * 0.22 * 4 * k * (1 - k)
            }
            if k >= 1 { pet.y = from.y }
            return k >= 1 && engine.currentID != "pounce" && engine.currentID != "land"
        }
    }

    private func updateChase(_ dt: Double) -> Bool {
        let mouse = NSEvent.mouseLocation
        // Lose interest after a while, or when the pointer stops or leaves, or you get back to work.
        if clock - lastMouseMoved > 2.5 || clock - chaseStarted > 15 || !pet.currentScreen().frame.contains(mouse) || userBusy {
            chaseCooldown = 20
            engine.request("idle_sit", force: true)
            return true
        }
        let target = clampToSurface(Double(mouse.x) - catW / 2)
        if abs(target - brain.x) < catW * 0.35 {
            if pouncedAt != nil {
                // Already caught it there: sit and see if you play.
                steps = [.watchForPlay(seconds: 3)]
            } else if Double(mouse.y) < pet.y + catH * 1.5 {
                // Close and low: crouch, pounce. Then see if you play back.
                pounceDir = Double(mouse.x) >= brain.x + catW / 2 ? 1 : -1
                brain.facingRight = pounceDir > 0
                steps = [.stalk(seconds: Double.random(in: 0.8...1.1), atPointer: true), .pounceAtAim, .watchForPlay(seconds: 3)]
            } else {
                // Out of reach above: just look up at it.
                steps = [.play("look_up", seconds: 1.5)]
                chaseCooldown = 10
            }
            return true
        }
        if engine.currentID != "chase" { engine.request("chase", force: true) }
        _ = move(toward: target, speed: brain.tuning.runSpeed * scale, dt: dt)
        return false
    }

    private func move(toward x: Double, speed: Double, dt: Double) -> Bool {
        let dx = x - brain.x
        if abs(dx) <= speed * dt { brain.x = x; return true }
        brain.facingRight = dx > 0
        brain.x += dx > 0 ? speed * dt : -speed * dt
        return false
    }

    private func finish() {
        current = nil
        pet.edgeClip = nil
        emergeY = nil
        involvedWindow = nil
        leap = nil
        engine.sustainLastFrame = false
        restoreLevel()
        brain.resumeAfterExtras()
    }

    private func restoreLevel() {
        guard hidden else { return }
        hidden = false
        pet.window.level = .floating
        pet.window.orderFrontRegardless()
    }

    /// Something took over (you picked the cat up) or the window it relied on vanished.
    func abort(dropping: Bool) {
        guard isActive else { return }
        steps = []
        current = nil
        pet.edgeClip = nil
        emergeY = nil
        involvedWindow = nil
        leap = nil
        engine.sustainLastFrame = false
        restoreLevel()
        if dropping { pet.startFall(vy: 0) }
        brain.resumeAfterExtras()
    }

    /// After each window scan: bail out if the window we're using closed or moved away.
    func windowsChanged() {
        guard isActive, let id = involvedWindow else { return }
        if !pet.windows.contains(where: { $0.id == id }) { abort(dropping: true) }
    }
}
