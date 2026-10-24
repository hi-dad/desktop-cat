import Foundation
import Testing
@testable import DesktopCat

/// Runs the brain and engine together on a fake clock.
final class Sim {
    let engine: AnimationEngine
    let brain: Brain
    var seen: [String] = []

    init(seed: UInt64, energy: Energy = .normal) {
        engine = AnimationEngine(library: library(0))
        brain = Brain(engine: engine, rng: SeededRNG(state: seed))
        brain.tuning = energy.tuning
        brain.floorRange = 0...1200
        brain.x = 600
    }

    func run(seconds: Double, dt: Double = 1.0 / 30, each: ((Double) -> Void)? = nil) {
        var t = 0.0
        while t < seconds {
            each?(t)
            engine.tick(dt)
            brain.update(dt)
            if seen.last != engine.currentID { seen.append(engine.currentID) }
            t += dt
        }
    }
}

@Suite struct BehaviorTests {
    @Test func twoHoursOnlyUseRealArtAndCoverTheBasics() {
        let sim = Sim(seed: 42)
        var idle = 0.0
        sim.run(seconds: 2 * 3600) { t in
            // 20 minutes of you working, then 15 minutes away, repeating.
            let away = t.truncatingRemainder(dividingBy: 2100) > 1200
            idle = away ? idle + 1.0 / 30 : 0
            sim.brain.userIdleSeconds = idle
            sim.brain.cursorOffset = Int(t) % 97 == 0 ? (dx: 20, dy: 120) : nil
            #expect(sim.brain.floorRange.contains(sim.brain.x))
        }
        let lib = library(0)
        for id in Set(sim.seen) {
            #expect(lib.action(id)!.hasRealArt, "behaviour picked \(id), which has no art")
        }
        for id in ["walk", "groom", "blink", "yawn", "lie_down", "sleep", "wake_up", "get_up", "look_up"] {
            #expect(sim.seen.contains(id), "never saw \(id)")
        }
    }

    @Test func sleepsWhileYouAreAwayAndWakesWhenYouReturn() {
        let sim = Sim(seed: 3)
        sim.brain.userIdleSeconds = 10_000
        sim.run(seconds: 20)
        #expect(sim.engine.currentID == "sleep")
        #expect(Array(sim.seen.suffix(3)) == ["yawn", "lie_down", "sleep"])
        sim.run(seconds: 600)
        #expect(sim.engine.currentID == "sleep", "keeps sleeping while you're away")

        sim.brain.userIdleSeconds = 0
        sim.seen = []
        sim.run(seconds: 10)
        #expect(Array(sim.seen.prefix(3)) == ["sleep", "wake_up", "get_up"])
        #expect(sim.engine.currentID != "sleep")
    }

    @Test func pausingLiesDownToSleepThenWakesSoonAfterResume() {
        let sim = Sim(seed: 7)
        sim.run(seconds: 30) // Whatever it's doing.
        sim.brain.settleForRest()
        var t = 0.0
        while !["sleep", "sleep_2"].contains(sim.engine.currentID) && t < 10 { sim.engine.tick(1.0 / 30); t += 1.0 / 30 }
        let asleep = ["sleep", "sleep_2"].contains(sim.engine.currentID)
        #expect(asleep)
        sim.seen = []
        sim.run(seconds: 10) // Resumed.
        #expect(sim.seen.contains("get_up"))
    }

    @Test func looksAtCursorAtMostEvery20Seconds() {
        let sim = Sim(seed: 5)
        sim.brain.tuning.weights = .init(idle: 1, walk: 0, groom: 0, rest: 0, look: 0)
        sim.brain.tuning.blinkEvery = 1000...1000
        sim.brain.cursorOffset = (dx: 30, dy: 150)
        sim.run(seconds: 19)
        #expect(sim.seen.filter { $0 == "look_up" }.count == 1)
        sim.run(seconds: 2)
        #expect(sim.seen.filter { $0 == "look_up" }.count == 2)
    }

    @Test func pawsAtTheScreenTwoOrThreeTimes() {
        for seed in UInt64(1)...10 {
            let sim = Sim(seed: seed)
            sim.brain.tuning.weights = .init(idle: 0, walk: 0, groom: 0, rest: 0, look: 0, paw: 1)
            sim.brain.tuning.blinkEvery = 1000...1000
            sim.brain.tuning.idleSeconds = 1...1
            sim.brain.resetToIdle()
            var paws = 0
            var burstOver = false
            sim.run(seconds: 10) { _ in
                guard !burstOver else { return }
                if sim.engine.currentID == "beg" && sim.engine.player.elapsed == 0 { paws += 1 }
                if paws > 0 && sim.engine.currentID == "idle_sit" { burstOver = true }
            }
            #expect(burstOver)
            #expect((2...3).contains(paws), "seed \(seed): pawed \(paws) times")
        }
    }

    @Test func idleWalksMostlyEndNearTheSides() {
        let sim = Sim(seed: 3)
        sim.brain.tuning.weights = .init(idle: 0, walk: 1, groom: 0, rest: 0, look: 0)
        sim.brain.tuning.chanceRun = 0
        var stops: [Double] = []
        var last = sim.engine.currentID
        sim.run(seconds: 1200) { _ in
            if last == "walk" && sim.engine.currentID == "idle_sit" { stops.append(sim.brain.x) }
            last = sim.engine.currentID
        }
        let r = sim.brain.floorRange, span = r.upperBound - r.lowerBound
        let sides = stops.filter { abs($0 - r.lowerBound) < span * 0.25 || abs($0 - r.upperBound) < span * 0.25 }
        #expect(stops.count > 20)
        #expect(Double(sides.count) / Double(stops.count) > 0.65)
    }

    @Test func calmWalksAlwaysEndInTheOuterThirds() {
        let sim = Sim(seed: 3, energy: .calm)
        sim.brain.tuning.weights = .init(idle: 0, walk: 1, groom: 0, rest: 0, look: 0)
        sim.brain.tuning.chanceRun = 0
        var stops: [Double] = []
        var last = sim.engine.currentID
        sim.run(seconds: 1200) { _ in
            if last == "walk" && sim.engine.currentID == "idle_sit" { stops.append(sim.brain.x) }
            last = sim.engine.currentID
        }
        let r = sim.brain.floorRange, span = r.upperBound - r.lowerBound
        let sides = stops.filter { abs($0 - r.lowerBound) <= span / 3 || abs($0 - r.upperBound) <= span / 3 }
        #expect(stops.count > 20)
        #expect(sides.count == stops.count, "stopped mid-screen")
        // Mostly pottering about on one side, sometimes crossing over.
        let crossings = zip(stops, stops.dropFirst()).filter { ($0 < 600) != ($1 < 600) }.count
        #expect(crossings > 0 && Double(crossings) / Double(stops.count) < 0.5)
    }

    @Test func calmSleepsInACornerAboutFortyPercentOfTheTime() {
        var total = 0.0, asleep = 0.0, cornerNaps = 0, naps = 0
        for seed in UInt64(1)...4 {
            let sim = Sim(seed: seed, energy: .calm)
            sim.brain.userIdleSeconds = 0.5 // You're at the Mac the whole time.
            var last = sim.engine.currentID
            sim.run(seconds: 3 * 3600) { _ in
                let id = sim.engine.currentID
                total += 1.0 / 30
                if id == "sleep" { asleep += 1.0 / 30 }
                if id == "lie_down" && last != "lie_down" {
                    naps += 1
                    if sim.brain.x < 150 || sim.brain.x > 1050 { cornerNaps += 1 }
                }
                last = id
            }
        }
        let share = asleep / total
        #expect(share > 0.3 && share < 0.5, "asleep \(Int(share * 100))% of the time")
        #expect(naps > 10 && cornerNaps == naps)
    }

    @Test func goesToASideBeforeFallingAsleep() {
        for seed in UInt64(1)...5 {
            let sim = Sim(seed: seed)
            sim.brain.x = 560 // Middle of the 0...1200 floor.
            sim.brain.userIdleSeconds = 10_000 // You're away: it settles in for a nap.
            var asleepAt: Double?
            sim.run(seconds: 120) { _ in
                if asleepAt == nil && sim.engine.currentID == "sleep" { asleepAt = sim.brain.x }
            }
            let x = try! #require(asleepAt)
            #expect(x < 300 || x > 900, "seed \(seed): fell asleep at \(x)")
        }
    }

    @Test func holdsALookUpForAMoment() {
        let sim = Sim(seed: 8)
        sim.brain.tuning.weights = .init(idle: 0, walk: 0, groom: 0, rest: 0, look: 1)
        sim.brain.tuning.blinkEvery = 1000...1000
        sim.brain.tuning.idleSeconds = 1...1
        sim.brain.resetToIdle()
        var longest = 0.0, t = 0.0
        sim.run(seconds: 60) { _ in
            t = sim.engine.currentID == "look_up" ? t + 1.0 / 30 : 0
            longest = max(longest, t)
        }
        #expect(longest > 2.5) // Plain look_up is 1.6 s; the gaze holds the head-up frame.
    }

    @Test func groomingRepeatsTwoToFourTimes() {
        for seed in UInt64(1)...20 {
            let sim = Sim(seed: seed)
            sim.brain.tuning.weights = .init(idle: 0, walk: 0, groom: 1, rest: 0, look: 0)
            sim.brain.tuning.blinkEvery = 1000...1000
            sim.brain.tuning.idleSeconds = 1...1
            sim.brain.resetToIdle() // Re-rolls the first wait with the new tuning.
            var grooms = 0
            var burstOver = false
            sim.run(seconds: 8) { _ in
                guard !burstOver else { return }
                if sim.engine.currentID == "groom" && sim.engine.player.elapsed == 0 { grooms += 1 }
                if grooms > 0 && sim.engine.currentID == "idle_sit" { burstOver = true }
            }
            #expect(burstOver)
            #expect((2...4).contains(grooms), "seed \(seed): groomed \(grooms) times")
        }
    }

    @Test func energyLevelsChangeHowOftenItDecides() {
        #expect(Energy.lively.tuning.idleSeconds.upperBound < Energy.normal.tuning.idleSeconds.lowerBound + 5)
        #expect(Energy.calm.tuning.weights.walk < Energy.lively.tuning.weights.walk)
    }
}
