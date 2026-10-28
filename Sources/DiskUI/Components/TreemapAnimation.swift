import SwiftUI

/// One box as it is drawn between two layouts.
///
/// `tile` is the box the current layout asks for; `rect`, `fill`, and `alpha` are
/// where it is drawn right now, on the way there.
struct TreemapAnimatedTile: Equatable {
    var tile: TreemapTile
    var rect: CGRect
    var fill: ChartFill
    var alpha: Double
}

/// The treemap's motion, in the frames between two layouts.
///
/// Every drawn value approaches the value the current layout asks for by the
/// same frame-rate independent step the sunburst uses:
///
///     value += (target - value) * (1 - exp(-dt * response))
///
/// A box new to the chart starts at 60 % of its rectangle, centred on it, and
/// fades in, so it opens out of the layout instead of appearing whole. A box the
/// layout drops keeps its last rectangle and fades out underneath. A resize is
/// not a new layout: adopting puts every box where the new size asks for it
/// without motion.
final class TreemapAnimator {
    /// Response of the rectangle and opacity approach, in reciprocal seconds.
    private static let response = 12.0
    /// How much of its rectangle a box occupies on its first frame.
    private static let enteringScale = 0.6

    /// Every box to draw: the fading ones, then the boxes that are standing.
    private(set) var drawn: [TreemapAnimatedTile] = []
    private(set) var isSettled = true

    private var alive: [TreemapAnimatedTile] = []
    private var fading: [TreemapAnimatedTile] = []

    /// The box drawn for `key`, whether it is live or still fading.
    func tile(forKey key: String) -> TreemapAnimatedTile? {
        alive.first { $0.tile.key == key } ?? fading.first { $0.tile.key == key }
    }

    /// Points the animator at a layout. `animated` false adopts it as it stands,
    /// which is what Reduce Motion does. `intro` is read only when the animator
    /// is empty: a fresh chart starts from the centre instead of appearing
    /// settled in its first frame.
    func setTarget(_ tiles: [TreemapTile], animated: Bool, intro: Bool = false) {
        guard animated else {
            adopt(tiles)
            return
        }
        guard !alive.isEmpty else {
            if intro, !tiles.isEmpty {
                reveal(tiles)
            } else {
                adopt(tiles)
            }
            return
        }

        var live: [String: TreemapAnimatedTile] = [:]
        for drawing in alive { live[drawing.tile.key] = drawing }
        var dead: [String: TreemapAnimatedTile] = [:]
        for drawing in fading { dead[drawing.tile.key] = drawing }

        var next: [TreemapAnimatedTile] = []
        next.reserveCapacity(tiles.count)
        for tile in tiles {
            var drawing = live.removeValue(forKey: tile.key)
                ?? dead.removeValue(forKey: tile.key)
                ?? Self.entering(tile)
            drawing.tile = tile
            next.append(drawing)
        }

        // Whatever the layout does not draw keeps its rectangle and fades, so a
        // changed chart reads as a change rather than a cut.
        var gone = Array(dead.values)
        for drawing in live.values { gone.append(drawing) }
        alive = next
        fading = gone
        isSettled = false
        refresh()
    }

    /// The chart has nothing to draw: drop everything.
    func reset() {
        alive = []
        fading = []
        isSettled = true
        refresh()
    }

    /// Finishes the motion at once — Reduce Motion, or a preference changed while
    /// a box was moving.
    func settle() {
        for index in alive.indices {
            alive[index].rect = alive[index].tile.rect
            alive[index].fill = alive[index].tile.fill
            alive[index].alpha = 1
        }
        fading = []
        isSettled = true
        refresh()
    }

    /// Advances the motion by `dt` seconds. Returns whether it has settled, which
    /// is what releases the frame driver.
    @discardableResult
    func step(dt: Double) -> Bool {
        guard !isSettled, dt > 0 else { return isSettled }
        let approach = 1 - exp(-dt * Self.response)
        var moving = false

        for index in alive.indices {
            var drawing = alive[index]
            drawing.rect = Self.lerp(drawing.rect, drawing.tile.rect, approach)
            drawing.fill = drawing.tile.fill
            drawing.alpha += (1 - drawing.alpha) * approach
            if abs(drawing.rect.minX - drawing.tile.rect.minX) > 0.3
                || abs(drawing.rect.minY - drawing.tile.rect.minY) > 0.3
                || abs(drawing.rect.width - drawing.tile.rect.width) > 0.3
                || abs(drawing.rect.height - drawing.tile.rect.height) > 0.3
                || drawing.alpha < 0.995 {
                moving = true
            }
            alive[index] = drawing
        }

        for index in fading.indices {
            var drawing = fading[index]
            // Exponential and linear together, so a fade always finishes.
            drawing.alpha = max(0, drawing.alpha - drawing.alpha * approach * 1.4 - dt * 0.5)
            fading[index] = drawing
        }
        fading.removeAll { $0.alpha <= 0.01 }
        if !fading.isEmpty { moving = true }

        if !moving {
            // The thresholds above stop inside a hair of the layout; land on it
            // exactly so a settled chart is the layout, not a near miss.
            for index in alive.indices {
                alive[index].rect = alive[index].tile.rect
                alive[index].fill = alive[index].tile.fill
                alive[index].alpha = 1
            }
        }

        isSettled = !moving
        refresh()
        return isSettled
    }

    /// The deepest box under `point`, or nil outside every box. Fading boxes are
    /// not targets: they are leaving.
    func tile(at point: CGPoint) -> TreemapAnimatedTile? {
        for drawing in drawn.reversed()
        where drawing.alpha > 0.3 && drawing.rect.contains(point) {
            return drawing
        }
        return nil
    }

    // MARK: - Internals

    private func reveal(_ tiles: [TreemapTile]) {
        alive = tiles.map { Self.entering($0) }
        fading = []
        isSettled = false
        refresh()
    }

    private func adopt(_ tiles: [TreemapTile]) {
        alive = tiles.map { tile in
            TreemapAnimatedTile(tile: tile, rect: tile.rect, fill: tile.fill, alpha: 1)
        }
        fading = []
        isSettled = true
        refresh()
    }

    /// Fading boxes first so they pass underneath, then the boxes that are
    /// standing, parents before children.
    private func refresh() {
        drawn = fading + alive
    }

    private static func entering(_ tile: TreemapTile) -> TreemapAnimatedTile {
        let inset = CGSize(
            width: tile.rect.width * (1 - enteringScale) / 2,
            height: tile.rect.height * (1 - enteringScale) / 2
        )
        return TreemapAnimatedTile(
            tile: tile,
            rect: tile.rect.insetBy(dx: inset.width, dy: inset.height),
            fill: tile.fill,
            alpha: 0
        )
    }

    private static func lerp(_ from: CGRect, _ to: CGRect, _ t: Double) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * CGFloat(t),
            y: from.minY + (to.minY - from.minY) * CGFloat(t),
            width: from.width + (to.width - from.width) * CGFloat(t),
            height: from.height + (to.height - from.height) * CGFloat(t)
        )
    }
}
