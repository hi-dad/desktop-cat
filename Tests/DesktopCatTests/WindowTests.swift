import CoreGraphics
import Foundation
import Testing
@testable import DesktopCat

@Suite struct WindowGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let cat = CGSize(width: 144, height: 144)

    @Test func topEdgeOfAWindowIsALedge() {
        let w = WindowRect(id: 1, frame: CGRect(x: 200, y: 100, width: 600, height: 400))
        #expect(WindowGeometry.ledges(windows: [w], screen: screen, catSize: cat) == [Ledge(windowID: 1, y: 500, minX: 200, maxX: 800)])
    }

    @Test func aWindowInFrontCutsTheLedge() {
        let back = WindowRect(id: 1, frame: CGRect(x: 200, y: 100, width: 800, height: 400))   // top at 500
        let front = WindowRect(id: 2, frame: CGRect(x: 450, y: 300, width: 200, height: 300))  // covers x 450–650 at the top
        let l = WindowGeometry.ledges(windows: [front, back], screen: screen, catSize: cat).filter { $0.windowID == 1 }
        #expect(l == [Ledge(windowID: 1, y: 500, minX: 200, maxX: 450), Ledge(windowID: 1, y: 500, minX: 650, maxX: 1000)])
    }

    @Test func aWindowBehindDoesNotCutIt() {
        let front = WindowRect(id: 1, frame: CGRect(x: 200, y: 100, width: 800, height: 400))
        let back = WindowRect(id: 2, frame: CGRect(x: 450, y: 300, width: 200, height: 300))
        let l = WindowGeometry.ledges(windows: [front, back], screen: screen, catSize: cat).filter { $0.windowID == 1 }
        #expect(l.count == 1 && l[0].width == 800)
    }

    @Test func onlyWindowsInFrontCanHideTheCatsPathBehindAnother() {
        let front = WindowRect(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 600))     // e.g. a white page in front
        let back = WindowRect(id: 2, frame: CGRect(x: 400, y: 0, width: 800, height: 500))
        let behind = WindowRect(id: 3, frame: CGRect(x: 1000, y: 0, width: 400, height: 400))
        let ws = [front, back, behind]
        // Walking behind window 2 through x 420–560: window 1 is in front there, so he'd vanish.
        #expect(WindowGeometry.coveredInFront(of: 2, CGRect(x: 420, y: 0, width: 140, height: 144), windows: ws))
        // Further right only window 3 overlaps, and it's behind window 2: fine.
        #expect(!WindowGeometry.coveredInFront(of: 2, CGRect(x: 900, y: 0, width: 200, height: 144), windows: ws))
    }

    @Test func noLedgeWhereTheCatWouldNotFit() {
        let tall = WindowRect(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 950))     // top too close to the menu bar
        let narrow = WindowRect(id: 2, frame: CGRect(x: 900, y: 100, width: 150, height: 300)) // narrower than 1.2 cats
        let low = WindowRect(id: 3, frame: CGRect(x: 1100, y: 0, width: 300, height: 50))     // top almost on the floor
        #expect(WindowGeometry.ledges(windows: [tall, narrow, low], screen: screen, catSize: cat).isEmpty)
    }

    @Test func landsOnTheHighestLedgeBelowItsCentre() {
        let ledges = [Ledge(windowID: 1, y: 300, minX: 0, maxX: 800), Ledge(windowID: 2, y: 600, minX: 400, maxX: 900),
                      Ledge(windowID: 3, y: 900, minX: 0, maxX: 1600)]
        #expect(WindowGeometry.surface(below: 700, catX: 500, catWidth: 144, ledges: ledges)?.windowID == 2)
        #expect(WindowGeometry.surface(below: 700, catX: 100, catWidth: 144, ledges: ledges)?.windowID == 1)
        #expect(WindowGeometry.surface(below: 200, catX: 100, catWidth: 144, ledges: ledges) == nil) // floor
    }

    @Test func convertsCoreGraphicsToCocoaCoordinates() {
        let r = WindowGeometry.cocoaRect(fromCG: CGRect(x: 10, y: 100, width: 300, height: 200), mainScreenHeight: 1000)
        #expect(r == CGRect(x: 10, y: 700, width: 300, height: 200))
    }

    @Test func spotsFullScreenWindows() {
        let full = WindowRect(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1040))
        #expect(WindowGeometry.hasFullScreenWindow([full], screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1040)))
        #expect(!WindowGeometry.hasFullScreenWindow([WindowRect(id: 2, frame: CGRect(x: 0, y: 0, width: 800, height: 600))],
                                                    screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1040)))
    }

    @Test func ledgeKeepsTheCatOnIt() {
        let l = Ledge(windowID: 1, y: 500, minX: 200, maxX: 800)
        let r = l.catRange(catWidth: 144)
        #expect(l.supports(catX: r.lowerBound, catWidth: 144) && l.supports(catX: r.upperBound, catWidth: 144))
    }
}

@Suite struct EngineAirTests {
    @Test func sustainHoldsTheLastFrameUntilReleased() {
        let engine = AnimationEngine(library: library(0))
        engine.request("fall", force: true)
        engine.sustainLastFrame = true
        engine.tick(5)
        engine.tick(5)
        #expect(engine.currentID == "fall")
        engine.sustainLastFrame = false
        engine.tick(1)
        #expect(engine.currentID != "fall")
    }

    @Test func freezeStopsOnTheCrouchFrame() {
        let engine = AnimationEngine(library: library(0))
        engine.request("pounce", force: true)
        engine.freeze(for: 0.5)
        engine.tick(0.4)
        #expect(engine.player.frameIndex == 0)
        engine.tick(0.2)
        engine.tick(0.15)
        #expect(engine.player.frameIndex > 0)
    }

    @Test func crouchAndClimbFramesAreReal() {
        for id in ["jump", "pounce", "climb", "peek", "hang_edge", "land", "fall"] {
            #expect(library(0).action(id)!.hasRealArt && library(1).action(id)!.hasRealArt, "\(id)")
        }
    }

    @Test func extrasOnlyGetATurnWhenSwitchedOn() {
        let sim = Sim(seed: 8)
        var asked = 0
        sim.run(seconds: 300)
        sim.brain.exploreHook = { asked += 1; return false }
        sim.run(seconds: 3600)
        #expect(asked > 10) // roughly 1 in 7 decisions, minus time spent napping
    }
}
