import XCTest
import AppKit
import SwiftUI
@testable import DiskUI

/// Independent verification that de-emphasized text is still readable.
///
/// The app resolves system label colors at draw time. This pins both
/// appearances, flattens the label's alpha over the window background, and
/// checks the contrast of the tokens the views use.
final class ContrastQATests: XCTestCase {

    func testMutedTextMeetsTextContrastInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            var contrast = 0.0
            appearance.performAsCurrentDrawingAppearance {
                let background = NSColor(DS.Color.windowBackground).usingColorSpace(.sRGB)!
                let foreground = NSColor(DS.Color.mutedText).usingColorSpace(.sRGB)!
                contrast = self.contrast(flatten(foreground, over: background), over: background)
            }
            XCTAssertGreaterThanOrEqual(contrast, 4.5,
                "\(name.rawValue): muted text must meet 4.5:1, got \(contrast)")
        }
    }

    func testSecondaryTextMeetsTheControlFloorInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            var contrast = 0.0
            appearance.performAsCurrentDrawingAppearance {
                let background = NSColor(DS.Color.windowBackground).usingColorSpace(.sRGB)!
                let foreground = NSColor(DS.Color.secondaryText).usingColorSpace(.sRGB)!
                contrast = self.contrast(flatten(foreground, over: background), over: background)
            }
            XCTAssertGreaterThanOrEqual(contrast, 3.0,
                "\(name.rawValue): secondary chrome must meet 3:1, got \(contrast)")
        }
    }

    /// Tertiary is a 1.88:1 text color. It survives only as the chart's
    /// fallback fill, so no view may reach for it again.
    func testTertiaryTextIsNotUsedInViews() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/DiskUI")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            if file.lastPathComponent == "DesignSystem.swift" || file.lastPathComponent == "ChartPalette.swift" {
                continue
            }
            if try String(contentsOf: file, encoding: .utf8).contains("tertiaryText") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "tertiaryText is a chart fill only; use mutedText or secondaryText")
    }

    private func flatten(_ color: NSColor, over background: NSColor) -> NSColor {
        let alpha = color.alphaComponent
        return NSColor(
            srgbRed: color.redComponent * alpha + background.redComponent * (1 - alpha),
            green: color.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: color.blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private func contrast(_ foreground: NSColor, over background: NSColor) -> Double {
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: NSColor) -> Double {
            0.2126 * linear(color.redComponent)
                + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        let a = luminance(foreground)
        let b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
