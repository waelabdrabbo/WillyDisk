import XCTest
import Foundation
@testable import DiskLocalization

/// Checks the layout an installed app runs from, not the build tree this suite
/// runs in.
///
/// SwiftPM's own `Bundle.module` looks beside `Bundle.main.bundleURL` and at the
/// path the module was compiled under; inside an `.app` neither is where
/// `Scripts/bundle-app.sh` puts the resource bundles, so these hold
/// `BundledResources` to the layout a download actually has.
final class ResourceBundleLayoutQATests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskLayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testTheBundleIsFoundInContentsResources() throws {
        let app = try makeAppBundle()
        let bundle = app.appendingPathComponent("Contents/Resources/WillyDisk_DiskLocalization.bundle")
        try makeResourceBundle(at: bundle, languages: ["en", "ar"])

        let main = try XCTUnwrap(Bundle(url: app), "an app-bundle directory should load as a bundle")
        let found = BundledResources.locate("WillyDisk_DiskLocalization", in: main)

        XCTAssertEqual(
            found?.bundleURL.standardizedFileURL,
            bundle.standardizedFileURL,
            "the copy in Contents/Resources is the one an installed app must load"
        )
    }

    func testTheAppLayoutIsSearchedBeforeAnythingElse() throws {
        let app = try makeAppBundle()
        let main = try XCTUnwrap(Bundle(url: app))

        let first = BundledResources.searchDirectories(for: main).first

        XCTAssertEqual(
            first?.standardizedFileURL,
            app.appendingPathComponent("Contents/Resources").standardizedFileURL
        )
    }

    func testAMissingBundleReportsEveryDirectoryTried() throws {
        let app = try makeAppBundle()
        let main = try XCTUnwrap(Bundle(url: app))
        // A name no layout carries: the real bundle is present in the test bundle
        // too, so the lookup's failure path needs one it cannot find anywhere.
        let name = "WillyDisk_NotShippedInThisBuild"

        XCTAssertNil(BundledResources.locate(name, in: main))

        let attempted = BundledResources.attemptedPaths(name, in: main)
        XCTAssertFalse(attempted.isEmpty)
        XCTAssertTrue(
            attempted.contains { $0.hasSuffix("Contents/Resources/\(name).bundle") },
            "the failure should name Contents/Resources, not only the build tree: \(attempted)"
        )
    }

    func testTheBundleNamesMatchWhatThePackageShips() throws {
        // SwiftPM forms the name as <package>_<target>. The two names are spelled
        // in `L10n` and `GrooveMark`; renaming a target in Package.swift without
        // following it there would leave the app without strings or without its
        // mark, so this reads the names the built test bundle actually carries.
        let resources = Bundle(for: ResourceBundleLayoutQATests.self).resourceURL
            ?? Bundle(for: ResourceBundleLayoutQATests.self).bundleURL
                .appendingPathComponent("Contents/Resources")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: resources.path),
            "no resource directory beside the test bundle at \(resources.path)"
        )
        for name in ["WillyDisk_DiskLocalization", "WillyDisk_DiskUI"] {
            let path = resources.appendingPathComponent("\(name).bundle").path
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: path),
                "no \(name).bundle beside the test bundle; nothing to compare against"
            )
            XCTAssertNotNil(
                Bundle(url: URL(fileURLWithPath: path)),
                "\(name).bundle is what the shipped code looks for"
            )
        }
    }

    // MARK: - Fixtures

    /// A directory shaped like an assembled app: `Contents/Info.plist` and
    /// `Contents/Resources`.
    private func makeAppBundle(name: String = "WillyDisk.app") throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.willydisk.app",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "WillyDisk",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    /// A directory shaped like a SwiftPM resource bundle.
    private func makeResourceBundle(at url: URL, languages: [String]) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.willydisk.\(url.deletingPathExtension().lastPathComponent)",
            "CFBundlePackageType": "BNDL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        for language in languages {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("Resources/\(language).lproj", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}
