import XCTest
@testable import DiskUpdate

/// The running build's facts, read the same way About and Diagnostics read them.
final class InstalledBuildTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskUpdateBuildTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testReadsTheBundlesVersionAndIdentifier() throws {
        let bundle = try makeBundle(
            identifier: "com.willydisk.app",
            version: "1.0.1"
        )
        let build = try XCTUnwrap(
            InstalledBuild.current(bundle: bundle, processInfo: .processInfo)
        )

        XCTAssertEqual(build.marketingVersion, "1.0.1")
        XCTAssertEqual(build.version, ReleaseVersion("1.0.1"))
        XCTAssertEqual(build.bundleIdentifier, "com.willydisk.app")
        XCTAssertEqual(build.architecture, .current)

        let system = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(build.operatingSystemVersion.majorVersion, system.majorVersion)
        XCTAssertEqual(build.operatingSystemVersion.minorVersion, system.minorVersion)
        XCTAssertEqual(build.operatingSystemVersion.patchVersion, system.patchVersion)
    }

    func testABundleWithoutAVersionIsNotComparable() throws {
        let bundle = try makeBundle(identifier: "com.willydisk.app", version: nil)
        XCTAssertNil(InstalledBuild.current(bundle: bundle, processInfo: .processInfo))
    }

    func testABundleWithoutAnIdentifierIsNotComparable() throws {
        let bundle = try makeBundle(identifier: nil, version: "1.0.1")
        XCTAssertNil(InstalledBuild.current(bundle: bundle, processInfo: .processInfo))
    }

    func testAnUnparseableVersionIsNotComparable() throws {
        let bundle = try makeBundle(identifier: "com.willydisk.app", version: "1.0.1.2")
        XCTAssertNil(InstalledBuild.current(bundle: bundle, processInfo: .processInfo))
    }

    private func makeBundle(identifier: String?, version: String?) throws -> Bundle {
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleName": "WillyDisk",
            "CFBundlePackageType": "APPL",
        ]
        if let identifier { plist["CFBundleIdentifier"] = identifier }
        if let version { plist["CFBundleShortVersionString"] = version }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: root))
    }
}
