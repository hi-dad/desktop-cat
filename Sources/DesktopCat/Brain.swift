import Foundation

/// How busy the cat is. Picked from the menu; each level is a set of tuning numbers.
enum Energy: String, CaseIterable {
    case calm, normal, lively

    var title: String { rawValue.capitalized }

    var tuning: BrainTuning {
        var t = BrainTuning()
        switch self {
        case .calm:
            t.idleSeconds = 12...25
            // Asleep in a corner about 40% of the time: naps come often and run long.
            t.weights = .init(idle: 50, walk: 15, groom: 12, rest: 25, look: 14, paw: 7)
            t.chanceRun = 0
            t.chanceNapAfterYawn = 0.9
            t.napSeconds = 120...300
            t.stayOnSides = true
        case .normal:
            break
        case .lively:
            t.idleSeconds = 5...12
            t.weights = .init(idle: 30, walk: 40, groom: 10, rest: 5, look: 20, paw: 14)
            t.chanceRun = 0.3
            t.chanceNapAfterYawn = 0.15
        }
        return t
    }
}

/// Every number that shapes behaviour, in one place. Defaults follow specs/BEHAVIOR_RULES.md.
struct BrainTuning {
    struct Weights {
        var idle = 45.0, walk = 25.0, groom = 10.0, rest = 10.0, look = 16.0
        /// Standing up on its hind legs and pawing at the screen (the beg frames).
        var paw = 10.0
        /// Only counts while a need is low: begging, looking sad or bored.
        var needs = 25.0
        /// Only counts while an opt-in extra (windows) is switched on.
        var explore = 20.0
        init() {}
        init(idle: Double, walk: Double, groom: Double, rest: Double, look: Double, paw: Double = 0, needs: Double = 25) {
            self.idle = idle; self.walk = walk; self.groom = groom; self.rest = rest; self.look = look
            self.paw = paw; self.needs = needs
        }
    }

    /// While awake, a new choice is made this often.
    var idleSeconds: ClosedRange<Double> = 8...18
    var weights = Weights()
    var blinkEvery: ClosedRange<Double> = 3...7
    var chanceRun = 0.1
    var groomRepeats: ClosedRange<Int> = 2...4
    var sitBackSeconds: ClosedRange<Double> = 4...8
    var chanceNapAfterYawn = 0.3
    var napSeconds: ClosedRange<Double> = 60...180
    /// Calm: keep strictly to the outer thirds and nap in a corner, well out of the way.
    var stayOnSides = false
    var chanceStretchAfterWaking = 0.6
    /// When you haven't touched the mouse or keyboard for this long, the cat goes to sleep.
    var sleepWhenAwaySeconds: ClosedRange<Double> = 180...480
    /// Once you're back, the cat wakes after this delay.
    var wakeDelay: ClosedRange<Double> = 1...4
    /// Looking at the cursor: how close it must be (sprite pixels) and the minimum gap between looks.
    var lookDistance = 80.0
    var lookCooldown = 20.0
    /// While you're working, the cat glances up at what you're doing about this often (and holds it a moment).
    var glanceEvery: ClosedRange<Double> = 15...35
    var gazeSeconds: ClosedRange<Double> = 1.5...4
    /// Standing up to paw at the screen: how many times in a row.
    var pawRepeats: ClosedRange<Int> = 2...3
    /// Sprite pixels per second (multiplied by scale for screen points).
    var walkSpeed = 15.0
    var runSpeed = 45.0
    /// How long a looping/holding action picked from the menu plays.
    var explicitSeconds = 5.0
    /// After you've been away this long, the cat waves when you come back.
    var waveAfterAwaySeconds = 60.0
    var waveRepeats = 2
    var bellyUpSeconds: ClosedRange<Double> = 3...5
    var eatSeconds: ClosedRange<Double> = 5...7
    var boredSeconds: ClosedRange<Double> = 4...7
}

/// A trip to a bowl you put down.
struct BowlErrand: Equatable {
    let need: Need            // .hunger (food bowl) or .thirst (water bowl)
    let propX: Double         // bowl's left edge on screen
    let propWidth: Double     // in screen points
    let placement: PropPlacement
}

/// A yarn-ball play session.
struct YarnErrand: Equatable {
    var roundsLeft: Int
    let placement: PropPlacement     // where the ball is at the start of play_yarn
    let endPlacement: PropPlacement  // where it is at the end (kicked from there)
}

/// The ball as the controller simulates it.
struct YarnBallState: Equatable {
    var x: Double       // left edge on screen
    var width: Double
    var vx: Double
    var onGround: Bool
}

/// Things the brain asks the controller to do with props.
enum BrainSignal: Equatable {
    case startedEating(Need)
    case stoppedEating(Need, finished: Bool)
    case pickedUpYarn
    /// Show the ball again at `fromX` and kick it this way (0 = just drop it there).
    case battedYarn(fromX: Double, direction: Double, last: Bool)
}

/// Decides what the cat does next and moves it along the floor.
/// Randomness only chooses among allowed actions; the engine plays them deterministically.
final class Brain {
    let engine: AnimationEngine
    var tuning = BrainTuning()
    var rng: any RandomNumberGenerator

    /// Feet position in screen points (x = left edge of the sprite).
    var x: Double = 0
    var facingRight = true
    /// Allowed x range for the sprite's left edge on the current floor.
    var floorRange: ClosedRange<Double> = 0...0
    /// Screen points per sprite pixel.
    var scale: Double = 3
    /// Seconds since the user last used the mouse or keyboard (set by the controller).
    var userIdleSeconds: Double = 0
    /// Cursor position relative to the cat's head, in screen points (+y is up), or nil if far away.
    var cursorOffset: (dx: Double, dy: Double)?

    private(set) var targetX: Double?
    private(set) var sleepingBecauseAway = false
    private var idleTimer: Double = 0
    private var blinkTimer: Double = 0
    private var actionTimer: Double = 0
    private var napTimer: Double = 0
    private var wakeTimer: Double?
    private var lookTimer: Double = 0
    private var groomLeft = 0
    private var pawLeft = 0
    /// Seconds to hold the looking-up pose once the head is all the way up (0 = don't).
    private var gazeHold = 0.0
    private var glanceTimer = 20.0
    /// Walking off to a side of the screen to curl up there.
    private var sleepOnArrival = false
    private var napAfterYawn = false
    private var waking = false
    private var sleepThreshold: Double = 300
    private var lastUserIdle: Double = 0
    private var pendingWave = false
    private var waveLeft = 0
    private var afterHappy: String?
    private(set) var isBeingPetted = false

    // Care
    var lowNeeds: Set<Need> = []
    private(set) var bowl: BowlErrand?
    private(set) var yarn: YarnErrand?
    var yarnBall: YarnBallState?
    private(set) var eating = false
    private var holdingYarn = false
    private var watchedToss = false
    private var signals: [BrainSignal] = []
    /// Width of the sprite on screen, in points.
    var spriteWidth: Double = 144
    /// Opt-in extras get a turn when the cat decides what to do. Returns true if one started.
    var exploreHook: (() -> Bool)?

    /// Where to sit to watch a playing video (the cat's left edge), nil when nothing is playing.
    var watchX: Double?
    private(set) var watching = false

    /// The surface under the cat moved sideways: keep heading for the same spot on it.
    func shiftTarget(by dx: Double) {
        if let t = targetX { targetX = t + dx }
    }

    /// An extra is driving the cat; forget any walk target.
    func pauseForExtras() {
        targetX = nil
        actionTimer = 0
    }

    /// An extra finished: settle back into normal behaviour.
    func resumeAfterExtras() {
        targetX = nil
        idleTimer = random(tuning.idleSeconds)
        blinkTimer = random(tuning.blinkEvery)
    }

    func takeSignals() -> [BrainSignal] {
        defer { signals = [] }
        return signals
    }

    init(engine: AnimationEngine, rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.engine = engine
        self.rng = rng
        idleTimer = random(tuning.idleSeconds)
        blinkTimer = random(tuning.blinkEvery)
        sleepThreshold = random(tuning.sleepWhenAwaySeconds)
        engine.onFinished = { [weak self] id in self?.finished(id) ?? false }
    }

    func update(_ dt: Double) {
        x = clamp(x)
        // Hold the head-up frame of a look up for a moment, as if watching what you're doing.
        if gazeHold > 0 {
            if engine.currentID != "look_up" { gazeHold = 0 } else if engine.frameIndex >= 2 { engine.freeze(for: gazeHold); gazeHold = 0 }
        }
        lookTimer -= dt
        if lastUserIdle >= tuning.waveAfterAwaySeconds && userIdleSeconds < 1 { pendingWave = true }
        lastUserIdle = userIdleSeconds
        if pendingWave && !sleepingBecauseAway && ["idle_sit", "walk", "run"].contains(engine.currentID) {
            wave()
            return
        }

        if ["idle_sit", "walk", "run", "chase"].contains(engine.currentID), runErrand(dt) { return }
        if let wx = watchX, bowl == nil, yarn == nil {
            if watchVideo(at: wx, dt) { return }
        } else if watching {
            watching = false
            if engine.currentID == "sit_back" { engine.request("idle_sit") }
            idleTimer = random(tuning.idleSeconds)
        }

        switch engine.currentID {
        case "walk", "run", "chase":
            moveTowardTarget(dt)
            if userIdleSeconds >= sleepThreshold && !sleepOnArrival { targetX = nil; goToSleep(away: true) }
        case "idle_sit":
            if userIdleSeconds >= sleepThreshold { goToSleep(away: true); return }
            if lookAtCursorIfNear() { return }
            glanceTimer -= dt
            if glanceTimer <= 0 {
                glanceTimer = random(tuning.glanceEvery)
                if userIdleSeconds < 4 && lookTimer <= 0 { gazeUp(); return } // Only while you're at it.
            }
            blinkTimer -= dt
            idleTimer -= dt
            if idleTimer <= 0 { decide() } else if blinkTimer <= 0 {
                blinkTimer = random(tuning.blinkEvery)
                engine.request("blink")
            }
        case "sleep", "sleep_2":
            updateSleep(dt)
        default:
            // Looping or holding actions (sit_back, menu picks) end on a timer.
            if engine.current.playback != .once && !isBeingPetted {
                actionTimer -= dt
                if actionTimer <= 0 {
                    if eating { finishEating() } else { engine.request("idle_sit") }
                }
            }
        }
    }

    /// Play an action picked by the user from the menu (playground).
    func playExplicit(_ id: String) {
        guard engine.request(id) else { return }
        sleepingBecauseAway = false
        actionTimer = engine.currentID == "sit_back" ? random(tuning.sitBackSeconds) : tuning.explicitSeconds
        napTimer = tuning.explicitSeconds
        if ["walk", "run", "chase"].contains(id) { pickTarget(minDistance: 150 * scale / 3) }
    }

    /// Called after a drop or screen change so the cat settles down.
    func resetToIdle() {
        interrupt()
        targetX = nil
        afterHappy = nil
        isBeingPetted = false
        sleepingBecauseAway = false
        waking = false
        idleTimer = random(tuning.idleSeconds)
        engine.request("idle_sit", force: true)
    }

    // MARK: - Choosing

    private func decide() {
        // Mid-screen it's in the way, so the next decision comes sooner.
        idleTimer = random(tuning.idleSeconds) * (inMiddle ? 0.5 : 1)
        let w = tuning.weights
        // Sitting around mid-screen is in the way: from there, wander off more often.
        let walkWeight = inMiddle ? w.walk * 2.5 : w.walk
        let choices: [(Double, () -> Void)] = [
            (inMiddle ? w.idle * 0.4 : w.idle, {}),
            (walkWeight, { [self] in
                pickTarget(minDistance: 60 * scale / 3)
                engine.request(chance(tuning.chanceRun) ? "run" : "walk")
            }),
            (w.groom, { [self] in
                groomLeft = Int.random(in: tuning.groomRepeats, using: &rng) - 1
                engine.request("groom")
            }),
            (w.rest, { [self] in
                if chance(0.5) {
                    engine.request("stretch")
                } else {
                    napAfterYawn = chance(tuning.chanceNapAfterYawn)
                    engine.request("yawn")
                }
            }),
            (w.look, { [self] in
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<6: gazeUp() // Looking up at what you're doing: the favourite.
                case 6, 7: engine.request("look_down")
                default:
                    actionTimer = random(tuning.sitBackSeconds)
                    engine.request("sit_back")
                }
            }),
            (w.paw, { [self] in
                // Up on its hind legs, pawing at the screen a few times.
                pawLeft = Int.random(in: tuning.pawRepeats, using: &rng) - 1
                engine.request("beg")
            }),
            (exploreHook == nil ? 0 : w.explore, { [self] in _ = exploreHook?() }),
            (lowNeeds.isEmpty ? 0 : w.needs, { [self] in
                // Ask for what's missing. bored borrows sit_back's frames (turning its back on you).
                let need = Need.allCases.filter(lowNeeds.contains).randomElement(using: &rng)!
                switch need {
                case .hunger: engine.request("beg")
                case .thirst: engine.request("sad")
                case .fun:
                    actionTimer = random(tuning.boredSeconds)
                    engine.request("bored")
                }
            }),
        ]
        var roll = Double.random(in: 0..<choices.reduce(0) { $0 + $1.0 }, using: &rng)
        for (weight, act) in choices {
            if roll < weight { act(); return }
            roll -= weight
        }
    }

    /// The engine calls this when a once/hold action ends. Returns true if we chose what's next.
    private func finished(_ id: String) -> Bool {
        switch id {
        case "beg" where pawLeft > 0:
            pawLeft -= 1
            return engine.request("beg")
        case "groom" where groomLeft > 0:
            groomLeft -= 1
            return engine.request("groom")
        case "yawn" where napAfterYawn:
            napAfterYawn = false
            napTimer = random(tuning.napSeconds)
            // Not in the middle of the screen: wander off to a side first, then lie down there.
            if let side = sideSpotForRest {
                targetX = side
                sleepOnArrival = true
                return engine.request("walk")
            }
            return engine.request("sleep") // Routed as lie_down → sleep.
        case "get_up" where waking:
            waking = false
            idleTimer = random(tuning.idleSeconds)
            if pendingWave { wave(); return true }
            return chance(tuning.chanceStretchAfterWaking) && engine.request("stretch")
        case "happy" where afterHappy != nil:
            let next = afterHappy!
            afterHappy = nil
            return engine.request(next)
        case "wave" where waveLeft > 0:
            waveLeft -= 1
            return engine.request("wave")
        case "play_yarn" where yarn != nil && holdingYarn:
            return batYarn()
        default:
            return false
        }
    }

    // MARK: - Reacting to you

    /// Tickling, petting and clicks. Dragging is handled by the controller (it overrides everything).
    func react(_ event: GestureEvent) {
        switch event {
        case .tickle:
            targetX = nil
            sleepingBecauseAway = false
            if engine.currentID == "roll_over" { return } // Already rolling about.
            actionTimer = random(tuning.bellyUpSeconds)
            if Transitions.lying.contains(engine.currentID) {
                engine.request("roll_over") // Already down: straight into a roll.
            } else {
                afterHappy = "roll_over" // Giggle first, then roll over (belly up mid-roll).
                engine.request("happy")
            }
        case .pettingBegan:
            isBeingPetted = true
            switch engine.currentID {
            case "sleep", "sleep_2": napTimer += 30 // Petting a sleeping cat keeps it asleep.
            case "belly_up", "knead": break
            default:
                targetX = nil
                engine.request("knead")
            }
        case .pettingEnded:
            isBeingPetted = false
            if engine.currentID == "knead" {
                idleTimer = random(tuning.idleSeconds)
                engine.request("happy")
            } else if engine.currentID == "belly_up" {
                actionTimer = min(actionTimer, 1.5)
            }
        }
    }

    /// A plain click on the cat: wakes a napping cat, otherwise it looks pleased.
    func poked() {
        switch engine.currentID {
        case "sleep", "sleep_2": wakeUp()
        case "idle_sit", "walk", "run", "blink", "sit_back":
            targetX = nil
            idleTimer = random(tuning.idleSeconds)
            engine.request("happy")
        default: break
        }
    }

    private func wave() {
        pendingWave = false
        targetX = nil
        waveLeft = tuning.waveRepeats - 1
        if let c = cursorOffset, abs(c.dx) > 4 * scale { facingRight = c.dx > 0 }
        idleTimer = random(tuning.idleSeconds)
        engine.request("wave")
    }

    // MARK: - Care errands

    /// You put a bowl down: the cat (waking up if needed) walks over and eats or drinks.
    func startBowl(_ errand: BowlErrand) {
        bowl = errand
        wakeForErrand()
    }

    /// You tossed the yarn: the cat chases and bats it `rounds` times.
    func startYarn(_ errand: YarnErrand) {
        yarn = errand
        watchedToss = false
        wakeForErrand()
    }

    /// Picked up mid-errand: put any bowl/ball back on screen; the errand resumes after landing.
    func interrupt() {
        sleepOnArrival = false
        if eating, let b = bowl {
            eating = false
            signals.append(.stoppedEating(b.need, finished: false))
        }
        if holdingYarn {
            holdingYarn = false
            let end = yarn.map { $0.placement.propX(forCatX: x, facingRight: facingRight, scale: scale) } ?? x
            signals.append(.battedYarn(fromX: end, direction: 0, last: false))
        }
    }

    private func wakeForErrand() {
        targetX = nil
        if Transitions.lying.contains(engine.currentID) {
            sleepingBecauseAway = false
            waking = true
            engine.request("get_up")
        }
    }

    /// Moves an errand along. Returns true if it took charge this frame.
    private func runErrand(_ dt: Double) -> Bool {
        if let b = bowl, !eating {
            let right = x + spriteWidth / 2 <= b.propX + b.propWidth / 2
            let target = clamp(b.placement.catX(forPropX: b.propX, facingRight: right, scale: scale))
            if abs(x - target) <= 1 {
                x = target
                facingRight = right
                targetX = nil
                eating = true
                actionTimer = random(tuning.eatSeconds)
                engine.request(b.need == .hunger ? "eat" : "drink")
                signals.append(.startedEating(b.need))
            } else {
                targetX = target
                if engine.currentID == "idle_sit" { engine.request("walk") } else { moveTowardTarget(dt) }
            }
            return true
        }
        if let y = yarn, !holdingYarn {
            guard let ball = yarnBall, ball.onGround else {
                // Watch it fly in.
                if !watchedToss && engine.currentID == "idle_sit" {
                    watchedToss = true
                    engine.request("look_up")
                }
                return engine.currentID == "idle_sit"
            }
            let right = x + spriteWidth / 2 <= ball.x + ball.width / 2
            let target = clamp(y.placement.catX(forPropX: ball.x, facingRight: right, scale: scale))
            if abs(x - target) <= 2 && abs(ball.vx) < 60 {
                x = target
                facingRight = right
                targetX = nil
                holdingYarn = true
                engine.request("play_yarn")
                signals.append(.pickedUpYarn)
            } else {
                targetX = target
                if engine.currentID != "chase" { engine.request("chase") } else { moveTowardTarget(dt) } // chase reuses run's frames
            }
            return true
        }
        return false
    }

    private func finishEating() {
        guard let b = bowl else { return }
        eating = false
        bowl = nil
        signals.append(.stoppedEating(b.need, finished: true))
        idleTimer = random(tuning.idleSeconds)
        engine.request("happy")
    }

    private func batYarn() -> Bool {
        guard var y = yarn else { return false }
        holdingYarn = false
        y.roundsLeft -= 1
        let last = y.roundsLeft <= 0
        let from = y.endPlacement.propX(forCatX: x, facingRight: facingRight, scale: scale)
        signals.append(.battedYarn(fromX: from, direction: facingRight ? 1 : -1, last: last))
        yarn = last ? nil : y
        idleTimer = random(tuning.idleSeconds)
        return last ? engine.request("happy") : false
    }

    // MARK: - Watching a video

    /// Walk over below the video and sit with its back to you, watching, for as long as it plays.
    private func watchVideo(at wx: Double, _ dt: Double) -> Bool {
        let id = engine.currentID
        if watching {
            if id == "sit_back" { return true }
            watching = false // Something else happened (petted, a blink): settle back in after.
        }
        guard ["idle_sit", "walk", "run", "blink", "look_up", "look_down"].contains(id) else { return false }
        let target = clamp(wx)
        if abs(x - target) <= 2 {
            x = target
            targetX = nil
            watching = true
            engine.request("sit_back")
        } else {
            targetX = target
            if id == "walk" || id == "run" { moveTowardTarget(dt) } else { engine.request("walk") }
        }
        return true
    }

    // MARK: - Sleeping

    /// The app is pausing: put down any errand and go to sleep; on resume it wakes soon after.
    /// Returns false if the cat can't head for sleep yet.
    @discardableResult func settleForRest() -> Bool {
        interrupt()
        targetX = nil
        afterHappy = nil
        isBeingPetted = false
        sleepingBecauseAway = false
        waking = false
        napAfterYawn = false
        napTimer = 3
        return engine.request("sleep") // Routed as lie_down → sleep.
    }

    private func goToSleep(away: Bool) {
        sleepingBecauseAway = away
        napAfterYawn = true
        napTimer = random(tuning.napSeconds)
        engine.request("yawn")
    }

    private func updateSleep(_ dt: Double) {
        if sleepingBecauseAway {
            // Sleep until you come back, then wake after a short, natural delay.
            if userIdleSeconds < 2 {
                if wakeTimer == nil { wakeTimer = random(tuning.wakeDelay) }
                wakeTimer! -= dt
                if wakeTimer! <= 0 { wakeUp() }
            } else {
                wakeTimer = nil
            }
            return
        }
        if userIdleSeconds >= sleepThreshold {
            sleepingBecauseAway = true // You left during a nap: keep sleeping until you're back.
            return
        }
        napTimer -= dt
        if napTimer <= 0 { wakeUp() }
    }

    private func wakeUp() {
        sleepingBecauseAway = false
        wakeTimer = nil
        waking = true
        sleepThreshold = random(tuning.sleepWhenAwaySeconds)
        engine.request("get_up") // Routed as wake_up → get_up; then maybe a stretch.
    }

    // MARK: - Looking at the cursor

    private func lookAtCursorIfNear() -> Bool {
        guard lookTimer <= 0, userIdleSeconds < 2, let c = cursorOffset else { return false }
        let reach = tuning.lookDistance * scale
        guard hypot(c.dx, c.dy) <= reach, abs(c.dy) > 10 * scale else { return false }
        lookTimer = tuning.lookCooldown
        if abs(c.dx) > 4 * scale { facingRight = c.dx > 0 }
        return engine.request(c.dy > 0 ? "look_up" : "look_down")
    }

    // MARK: - Walking

    private func pickTarget(minDistance: Double) {
        let span = floorRange.upperBound - floorRange.lowerBound
        guard span > minDistance else { targetX = floorRange.lowerBound; return }
        var t = x
        guard span > spriteWidth * 6 else {
            for _ in 0..<10 {
                t = Double.random(in: floorRange, using: &rng)
                if abs(t - x) >= minDistance { break }
            }
            targetX = t
            return
        }
        guard tuning.stayOnSides else {
            // Usually head for one of the sides, out of the way; now and then anywhere.
            let preferSides = chance(0.75)
            let band = span * 0.22
            for _ in 0..<10 {
                if preferSides {
                    t = chance(0.5) ? floorRange.lowerBound + Double.random(in: 0...band, using: &rng)
                                    : floorRange.upperBound - Double.random(in: 0...band, using: &rng)
                } else {
                    t = Double.random(in: floorRange, using: &rng)
                }
                if abs(t - x) >= minDistance { break }
            }
            targetX = t
            return
        }
        // Calm, out of the way: walks end in the outer third on either side, never mid-screen. Mostly
        // it potters about on the side it's on; now and then it walks right across to the other side.
        let third = span / 3
        let onLeft = x < (floorRange.lowerBound + floorRange.upperBound) / 2
        func spot(left: Bool) -> Double {
            left ? floorRange.lowerBound + Double.random(in: 0...third, using: &rng)
                 : floorRange.upperBound - Double.random(in: 0...third, using: &rng)
        }
        if inMiddle { targetX = spot(left: onLeft); return }
        if !chance(0.3) {
            for _ in 0..<10 {
                t = spot(left: onLeft)
                if abs(t - x) >= minDistance { targetX = t; return }
            }
        }
        targetX = spot(left: !onLeft)
    }

    /// Mid-screen on a wide floor, where sitting still gets in the way (the middle half; Calm: the middle third).
    private var inMiddle: Bool {
        let span = floorRange.upperBound - floorRange.lowerBound
        guard span > spriteWidth * 6 else { return false }
        let k = (x - floorRange.lowerBound) / span
        return tuning.stayOnSides ? k > 1 / 3 && k < 2 / 3 : k > 0.25 && k < 0.75
    }

    /// Somewhere near the nearer side to curl up (Calm: in the corner), or nil when it's already out of the way.
    var sideSpotForRest: Double? {
        let span = floorRange.upperBound - floorRange.lowerBound
        guard span > spriteWidth * 6 else { return nil }
        let band = span * (tuning.stayOnSides ? 0.12 : 0.18)
        let mid = (floorRange.lowerBound + floorRange.upperBound) / 2
        if tuning.stayOnSides {
            if x - floorRange.lowerBound <= band || floorRange.upperBound - x <= band { return nil }
        } else if !inMiddle {
            return nil
        }
        return x < mid ? floorRange.lowerBound + Double.random(in: 0...band, using: &rng)
                       : floorRange.upperBound - Double.random(in: 0...band, using: &rng)
    }

    /// Look up and hold it a moment.
    private func gazeUp() {
        if engine.request("look_up") { gazeHold = random(tuning.gazeSeconds) }
    }

    private func moveTowardTarget(_ dt: Double) {
        guard let target = targetX else { pickTarget(minDistance: 40); return }
        let speed = (engine.currentID == "walk" ? tuning.walkSpeed : tuning.runSpeed) * scale
        let dx = target - x
        facingRight = dx >= 0
        let step = speed * dt
        if abs(dx) <= step {
            x = target
            targetX = nil
            if bowl != nil || yarn != nil { return } // The errand takes it from here.
            if sleepOnArrival {
                sleepOnArrival = false
                engine.request("sleep") // Routed as lie_down → sleep.
                return
            }
            idleTimer = random(tuning.idleSeconds)
            engine.request("idle_sit")
        } else {
            x += dx > 0 ? step : -step
        }
        x = clamp(x)
    }

    // MARK: - Helpers

    private func clamp(_ value: Double) -> Double {
        min(max(value, floorRange.lowerBound), floorRange.upperBound)
    }

    private func random(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &rng)
    }

    private func chance(_ p: Double) -> Bool {
        Double.random(in: 0..<1, using: &rng) < p
    }
}
