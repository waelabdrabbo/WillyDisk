import Combine
import SwiftUI
import DiskCore

/// How far an entering wedge has opened, from its inner edge to its rim.
///
/// A cubic ease-out: most of the band appears early and it settles at the rim,
/// so a new wedge grows out of the platter rather than appearing whole.
func sunburstEase(_ t: Double) -> Double {
    let progress = min(max(t, 0), 1)
    return 1 - pow(1 - progress, 3)
}

/// The category ring's entrance: one band that opens clockwise from 12 o'clock.
///
/// The ring has no depth to stagger and no keys to carry between layouts, so its
/// entrance is the reveal alone — the slice at 12 o'clock starts at once and each
/// one further round waits a little longer, closing the full circle as a wave.
enum CategoryRingEntrance {
    /// Seconds from the first slice starting to the last one finishing.
    static let duration = 0.45
    /// Of those seconds, how many the slice a full turn round waits.
    static let turnDelay = 0.09

    /// How much of the slice starting at `start` is open after `elapsed`
    /// seconds, from 0 to 1.
    static func reveal(elapsed: Double, start: Double) -> Double {
        let turn = start / (2 * .pi)
        let delay = turnDelay * min(max(turn, 0), 1)
        let opening = max(duration - turnDelay, 0.001)
        return sunburstEase((elapsed - delay) / opening)
    }
}

/// One wedge's drawn shape between two layouts.
///
/// The layout is only rebuilt when the tree or the focus changes
/// (`SunburstLayout`). Between those rebuilds these values carry a wedge from
/// where it was to where the new layout wants it, so a chart never jumps. Depth
/// is fractional for the same reason: a wedge that moves from one ring to
/// another is drawn in between them while it moves.
struct SunburstAnimatedWedge: Equatable {
    /// Stable across layouts. A node keeps its key when it moves to another
    /// ring, which is what makes a drill a move rather than a replacement.
    let key: String
    /// Angle from 12 o'clock, in radians, increasing clockwise.
    var start: Double
    var end: Double
    /// Ring index, fractional while the wedge moves. Ring 1 is the focused
    /// directory's children, as in `SunburstSegment.ring`.
    var depth: Double
    var alpha: Double
    /// Reveal of the radial band: negative while the wedge waits its turn, then
    /// 0...1 as it opens from its inner edge. Read through `sunburstEase`.
    var grow: Double
    var fill: ChartFill
    var targetStart: Double
    var targetEnd: Double
    var targetDepth: Double
}

/// The sunburst's motion, in the frames between two layouts.
///
/// Every drawn value approaches the value the current layout asks for by the
/// same frame-rate independent step:
///
///     value += (target - value) * (1 - exp(-dt * response))
///
/// which is a first-order exponential approach: no spring, no overshoot, and
/// the same feel whether the display runs at 60 or 120 Hz. A wedge new to the
/// chart instead starts invisible and opens its band after a delay that grows
/// with its ring and its angle, so a rebuilt chart reveals as a wave running
/// outwards and clockwise. A wedge the layout drops keeps its shape and fades
/// out underneath the live ones.
///
/// The disc's division into rings moves with it: drilling into a folder whose
/// tree is shallower than the one before it lowers the ring count, and the
/// bands re-divide over a few frames instead of snapping.
final class SunburstAnimator {
    /// Response of the angle, ring, and opacity approach, in reciprocal
    /// seconds. The time constant is about 90 ms.
    private static let response = 11.0
    /// How fast a wedge reveals, in reveal units per second.
    private static let revealRate = 2.6
    /// Reveal delay an entering wedge takes per ring it sits out, in reveal
    /// units, and per full turn clockwise from 12 o'clock.
    private static let staggerPerRing = 0.12
    private static let staggerPerTurn = 0.25

    /// Every wedge to draw: the fading ones, then the wedges that are standing,
    /// then the ones still arriving (see `refresh`).
    private(set) var drawn: [SunburstAnimatedWedge] = []
    /// How many rings the disc is currently divided into; fractional while the
    /// chart re-divides itself after a drill.
    private(set) var ringSpan = 1.0
    private(set) var isSettled = true

    private var alive: [SunburstAnimatedWedge] = []
    private var fading: [SunburstAnimatedWedge] = []
    private var targetRingSpan = 1.0

    /// The wedge drawn for `key`, whether it is live or still fading.
    func wedge(forKey key: String) -> SunburstAnimatedWedge? {
        alive.first { $0.key == key } ?? fading.first { $0.key == key }
    }

    /// Points the animator at a layout. `animated` false adopts the layout as
    /// it stands, which is what Reduce Motion does.
    ///
    /// `intro` is read only when the animator is empty: a fresh chart that asks
    /// for it starts hidden and opens as the wave described on the type, rather
    /// than appearing settled in its first frame.
    func setTarget(_ segments: [SunburstSegment], animated: Bool, intro: Bool = false) {
        guard animated else {
            adopt(segments)
            return
        }
        guard !alive.isEmpty else {
            if intro, !segments.isEmpty {
                reveal(segments)
            } else {
                adopt(segments)
            }
            return
        }

        var live: [String: SunburstAnimatedWedge] = [:]
        for wedge in alive { live[wedge.key] = wedge }
        var dead: [String: SunburstAnimatedWedge] = [:]
        for wedge in fading { dead[wedge.key] = wedge }
        var next: [SunburstAnimatedWedge] = []
        next.reserveCapacity(segments.count)

        for segment in segments {
            var wedge = live.removeValue(forKey: segment.key)
                ?? dead.removeValue(forKey: segment.key)
                ?? Self.entering(segment)
            wedge.fill = segment.fill
            wedge.targetStart = segment.start
            wedge.targetEnd = segment.end
            wedge.targetDepth = Double(segment.ring)
            next.append(wedge)
        }

        // Whatever the new layout does not draw holds its shape and fades, so a
        // replaced chart reads as a change rather than a cut. `dead` holds only
        // the wedges that were already fading and were not drawn again, so the
        // two lists partition everything the animator knows.
        var gone = Array(dead.values)
        for var wedge in live.values {
            wedge.targetStart = wedge.start
            wedge.targetEnd = wedge.end
            wedge.targetDepth = wedge.depth
            gone.append(wedge)
        }
        alive = next
        fading = gone
        targetRingSpan = Self.span(of: segments)
        isSettled = false
        refresh()
    }

    /// The chart has nothing to draw: drop everything.
    func reset() {
        alive = []
        fading = []
        ringSpan = 1
        targetRingSpan = 1
        isSettled = true
        refresh()
    }

    /// Finishes the motion at once — Reduce Motion, or a preference changed
    /// while a wedge was moving.
    func settle() {
        for index in alive.indices {
            alive[index].start = alive[index].targetStart
            alive[index].end = alive[index].targetEnd
            alive[index].depth = alive[index].targetDepth
            alive[index].alpha = 1
            alive[index].grow = 1
        }
        fading = []
        ringSpan = targetRingSpan
        isSettled = true
        refresh()
    }

    /// Advances the motion by `dt` seconds. Returns whether anything is still
    /// moving, which is what releases the frame driver.
    @discardableResult
    func step(dt: Double) -> Bool {
        guard !isSettled, dt > 0 else { return isSettled }
        let approach = 1 - exp(-dt * Self.response)
        var moving = false

        ringSpan += (targetRingSpan - ringSpan) * approach
        if abs(targetRingSpan - ringSpan) > 0.001 { moving = true }

        for index in alive.indices {
            var wedge = alive[index]
            wedge.start += (wedge.targetStart - wedge.start) * approach
            wedge.end += (wedge.targetEnd - wedge.end) * approach
            wedge.depth += (wedge.targetDepth - wedge.depth) * approach
            wedge.alpha += (1 - wedge.alpha) * approach
            wedge.grow = min(1, wedge.grow + dt * Self.revealRate)
            if abs(wedge.targetStart - wedge.start) > 1e-3
                || abs(wedge.targetEnd - wedge.end) > 1e-3
                || abs(wedge.targetDepth - wedge.depth) > 1e-2
                || wedge.alpha < 0.995
                || wedge.grow < 1 {
                moving = true
            }
            alive[index] = wedge
        }

        for index in fading.indices {
            var wedge = fading[index]
            // Exponential and linear together, so a fade always finishes.
            wedge.alpha = max(0, wedge.alpha - wedge.alpha * approach * 1.4 - dt * 0.5)
            fading[index] = wedge
        }
        fading.removeAll { $0.alpha <= 0.01 }
        if !fading.isEmpty { moving = true }

        if !moving {
            // The thresholds above stop inside a hair of the layout; land on it
            // exactly so a settled chart is the layout, not a near miss.
            for index in alive.indices {
                alive[index].start = alive[index].targetStart
                alive[index].end = alive[index].targetEnd
                alive[index].depth = alive[index].targetDepth
                alive[index].alpha = 1
                alive[index].grow = 1
            }
            ringSpan = targetRingSpan
        }

        isSettled = !moving
        refresh()
        return isSettled
    }

    /// Starts a chart that has nothing yet: every wedge waits its turn, then
    /// opens out of the platter. The rings already sit at their final widths, so
    /// only the reveal moves and the picture arrives rather than re-laying-out.
    private func reveal(_ segments: [SunburstSegment]) {
        alive = segments.map { Self.entering($0) }
        fading = []
        ringSpan = Self.span(of: segments)
        targetRingSpan = ringSpan
        isSettled = false
        refresh()
    }

    private func adopt(_ segments: [SunburstSegment]) {
        alive = segments.map { segment in
            SunburstAnimatedWedge(
                key: segment.key,
                start: segment.start,
                end: segment.end,
                depth: Double(segment.ring),
                alpha: 1,
                grow: 1,
                fill: segment.fill,
                targetStart: segment.start,
                targetEnd: segment.end,
                targetDepth: Double(segment.ring)
            )
        }
        fading = []
        ringSpan = Self.span(of: segments)
        targetRingSpan = ringSpan
        isSettled = true
        refresh()
    }

    /// Fading wedges first so they pass underneath, then the wedges that are
    /// standing, then the ones still arriving on top: a wedge opening out of the
    /// plate paints over the neighbours that are moving out of its way, so its
    /// reveal is never cut in half by a wedge that is about to leave the space.
    private func refresh() {
        var arriving: [SunburstAnimatedWedge] = []
        var standing: [SunburstAnimatedWedge] = []
        standing.reserveCapacity(alive.count)
        for wedge in alive {
            if wedge.alpha < 0.999 || wedge.grow < 1 {
                arriving.append(wedge)
            } else {
                standing.append(wedge)
            }
        }
        drawn = fading + standing + arriving
    }

    private static func span(of segments: [SunburstSegment]) -> Double {
        Double(max(segments.map(\.ring).max() ?? 1, 1))
    }

    private static func entering(_ segment: SunburstSegment) -> SunburstAnimatedWedge {
        let turn = segment.start / (2 * .pi)
        // The inner ring opens at once; each ring further out waits a beat, and
        // the wave runs clockwise from 12 o'clock.
        let delay = staggerPerRing * Double(segment.ring - 1) + staggerPerTurn * turn
        return SunburstAnimatedWedge(
            key: segment.key,
            start: segment.start,
            end: segment.end,
            depth: Double(segment.ring),
            alpha: 0,
            grow: -delay,
            fill: segment.fill,
            targetStart: segment.start,
            targetEnd: segment.end,
            targetDepth: Double(segment.ring)
        )
    }
}

/// Drives an animation at display rate while it is on screen.
///
/// The animation owns no timer of its own: this view exists only while
/// something is moving, so an idle chart asks for no frames at all. `dt` comes
/// from the ticks rather than from a fixed step, which is what lets the
/// animator's exponential approach stay smooth on a display of any rate.
struct ChartTicker: View {
    /// Called once per frame with the seconds since the previous call.
    let tick: (Double) -> Void

    @State private var lastTick: Date?
    @State private var clock = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(clock) { now in
                let elapsed = lastTick.map { now.timeIntervalSince($0) } ?? (1.0 / 60)
                lastTick = now
                tick(min(max(elapsed, 1.0 / 240), 0.1))
            }
    }
}
