import CoreGraphics
import Foundation

/// Another app's window, in Cocoa screen coordinates (origin bottom-left, y up).
struct WindowRect: Equatable {
    let id: Int
    let frame: CGRect
    var pid: Int = 0
}

/// A stretch of a window's top edge the cat can stand on.
struct Ledge: Equatable {
    let windowID: Int
    let y: Double
    let minX: Double
    let maxX: Double

    var width: Double { maxX - minX }

    /// Range for the cat's left edge so it stays on the ledge (a little overhang is fine).
    func catRange(catWidth w: Double) -> ClosedRange<Double> {
        let lo = minX - w * 0.2, hi = maxX - w * 0.8
        return lo <= hi ? lo...hi : lo...lo
    }

    func supports(catX x: Double, catWidth w: Double) -> Bool {
        let center = x + w / 2
        return center >= minX && center <= maxX
    }
}

/// Where the cat is standing.
enum Surface: Equatable {
    case floor
    case ledge(windowID: Int)
}

/// Pure geometry over window frames. No permissions are involved: macOS shares
/// window positions and stacking order with every app (only titles and contents need
/// Screen Recording, and the cat never asks for them).
enum WindowGeometry {
    /// Top edges the cat can stand on. `windows` must be front-to-back (as macOS lists them).
    /// A ledge is dropped where a window in front covers it or the space just above it,
    /// where it's too close to the top of the screen for the cat to fit, or too short.
    static func ledges(windows: [WindowRect], screen: CGRect, catSize: CGSize) -> [Ledge] {
        let catW = Double(catSize.width), catH = Double(catSize.height)
        var result: [Ledge] = []
        for (i, w) in windows.enumerated() {
            let top = Double(w.frame.maxY)
            guard top + catH <= Double(screen.maxY), top > Double(screen.minY) + catH * 0.5 else { continue }
            var segments = [(max(Double(w.frame.minX), Double(screen.minX)), min(Double(w.frame.maxX), Double(screen.maxX)))]
            for front in windows[..<i] {
                let f = front.frame
                // Covers the edge itself or the band where the cat would stand.
                guard Double(f.minY) < top + catH * 0.8, Double(f.maxY) > top - 2 else { continue }
                segments = subtract(segments, Double(f.minX), Double(f.maxX))
            }
            for (lo, hi) in segments where hi - lo >= catW * 1.2 {
                result.append(Ledge(windowID: w.id, y: top, minX: lo, maxX: hi))
            }
        }
        return result
    }

    /// The highest ledge at or below `y` under the cat's centre, or nil for the floor.
    static func surface(below y: Double, catX: Double, catWidth: Double, ledges: [Ledge]) -> Ledge? {
        ledges.filter { $0.y <= y + 0.5 && $0.supports(catX: catX, catWidth: catWidth) }.max { $0.y < $1.y }
    }

    /// True when some window fills the whole screen (a full-screen app or video).
    /// Tucked behind window `id`, the cat is behind every window in front of it too (`windows` is front
    /// to back). True when one of those covers `rect`: it would vanish there instead of behind `id`.
    static func coveredInFront(of id: Int, _ rect: CGRect, windows: [WindowRect]) -> Bool {
        guard let i = windows.firstIndex(where: { $0.id == id }) else { return true }
        return windows[..<i].contains { $0.frame.intersects(rect) }
    }

    static func hasFullScreenWindow(_ windows: [WindowRect], screenFrame: CGRect) -> Bool {
        windows.contains {
            abs($0.frame.minX - screenFrame.minX) < 2 && abs($0.frame.minY - screenFrame.minY) < 2 &&
                abs($0.frame.width - screenFrame.width) < 2 && abs($0.frame.height - screenFrame.height) < 2
        }
    }

    static func subtract(_ segments: [(Double, Double)], _ lo: Double, _ hi: Double) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (a, b) in segments {
            if hi <= a || lo >= b { out.append((a, b)); continue }
            if lo > a { out.append((a, lo)) }
            if hi < b { out.append((hi, b)) }
        }
        return out
    }

    /// Converts a CoreGraphics window rect (origin top-left of the main display) to Cocoa coordinates.
    static func cocoaRect(fromCG r: CGRect, mainScreenHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
