import AppKit
import SwiftUI

/// The app's mark as the one image the UI draws.
///
/// `Scripts/make-icon.swift` writes this cut — the mark on its own circle, with
/// no platform body — into the target's resources, so the hero, the results
/// screen, Help, and About all show the same artwork at any size. The macOS app
/// icon is that drawing on the rounded-square body the platform expects.
///
/// `NSImage` is AppKit UI state, so the image is main-actor isolated rather than
/// a global shared across threads.
@MainActor
public enum AppMarkImage {
    public static let shared: NSImage = {
        guard let url = Bundle.module.url(forResource: "AppMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            // The mark is committed artwork, not something drawn at runtime, so a
            // missing resource is a packaging fault rather than a state to show.
            fatalError("AppMark.png is missing from the DiskUI resource bundle")
        }
        return image
    }()
}

/// The mark at any size.
///
/// One image rather than a shape drawn in code: it is the same cut the icon is
/// built from, so the two cannot drift apart, and the mark stays the identical
/// object in both appearances.
struct WillyDiskMark: View {
    var size: CGFloat = 48

    var body: some View {
        Image(nsImage: AppMarkImage.shared)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
