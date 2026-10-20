import SwiftUI

/// One groove of the platter: a ring cut by a single narrow slot.
///
/// Bearings are degrees clockwise from twelve o'clock, so stacked grooves put
/// their slots on the same bearing and read as one disc cut once. `from` and `to`
/// select a portion of the ring, measured from the slot clockwise.
struct GrooveRing: Shape {
    /// Radius of the groove, in grid units of a 24×24 mark.
    var radius: CGFloat
    /// Bearing of the slot's centre, clockwise from twelve o'clock.
    var slotBearing: Double = 90
    /// Half-width of the slot, in degrees.
    var slot: Double = 5
    var from: Double = 0
    var to: Double = 1

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let sweep = 360 - slot * 2
        let start = slotBearing + slot + sweep * min(max(from, 0), 1)
        let end = slotBearing + slot + sweep * min(max(to, 0), 1)
        var path = Path()
        guard end > start else { return path }

        let steps = max(8, Int((end - start) / 1.5))
        for step in 0...steps {
            let bearing = start + (end - start) * Double(step) / Double(steps)
            let radians = bearing * .pi / 180
            let point = CGPoint(
                x: center.x + radius * unit * sin(radians),
                y: center.y - radius * unit * cos(radians)
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// The mark: the app icon at any size — an ink platter, its grooves, one slot,
/// and one lit sector.
///
/// Drawn with the icon's own colours rather than the text tokens, so it stays an
/// object in both appearances: a light theme shows the ink disc, and a dark one
/// lets the ground disappear into the window while the grooves and the lit
/// sector stay legible. Below 32 points the inner groove and the slot would
/// crowd into a disc, so the mark keeps a single heavier groove and a longer
/// lit sector — the compact cut the icon uses at its smallest representations.
struct WillyDiskMark: View {
    var size: CGFloat = 48
    /// Lights the outer groove's last stretch in signal. Off for the mark in
    /// running copy, where the colour would be decoration.
    var showsLiveSector: Bool = true

    private var isCompact: Bool { size < 32 }
    private var grooves: [CGFloat] { isCompact ? [7.2] : [5.5, 9.0] }
    private var lineWidth: CGFloat { size * (isCompact ? 2.4 : 1.75) / 24 }
    private var slot: Double { isCompact ? 8 : 7 }
    /// The lit stretch runs from this fraction of the groove to its end at the
    /// slot, so the sector and the cut meet.
    private var litFrom: Double { isCompact ? 0.6 : 0.72 }
    private var spindleDiameter: CGFloat { size * (isCompact ? 1.5 : 1.35) * 2 / 24 }

    var body: some View {
        ZStack {
            Circle().fill(DS.Color.plateGround)
            ForEach(grooves.indices, id: \.self) { index in
                GrooveRing(radius: grooves[index], slot: slot)
                    .stroke(DS.Color.plateGroove, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            if showsLiveSector, let outer = grooves.last {
                GrooveRing(radius: outer, slot: slot, from: litFrom, to: 1)
                    .stroke(DS.Color.plateSignal, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            // The spindle is turned enamel, as on the app icon: the dot is what
            // makes the centre read as a spindle rather than as solid ink.
            Circle()
                .fill(DS.Color.plateGroove)
                .frame(width: spindleDiameter, height: spindleDiameter)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
