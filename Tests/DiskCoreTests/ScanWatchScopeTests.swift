import XCTest
@testable import DiskCore

/// The event filter: what a scan of a root counts as its own tree, and what a
/// batch of FSEvents paths is reduced to.
final class ScanWatchScopeTests: XCTestCase {

    private struct FakeProbe: ScanVolumeProbing {
        var devices: [String: dev_t] = [:]

        func device(ofNearestExisting path: String) -> dev_t? {
            devices[path]
        }
    }

    private func scope(
        root: String = "/scan/tree",
        excluded: [String] = [],
        stayOnVolume: Bool = false,
        rootDevice: dev_t? = nil,
        probe: FakeProbe = FakeProbe()
    ) -> ScanWatchScope {
        ScanWatchScope(
            root: URL(fileURLWithPath: root),
            excludedPaths: excluded.map { URL(fileURLWithPath: $0) },
            stayOnVolume: stayOnVolume,
            rootDevice: rootDevice,
            probe: probe
        )
    }

    // MARK: - Root boundary

    func testRootBoundaryIsComponentWise() {
        let scope = scope()
        XCTAssertTrue(scope.includes(path: "/scan/tree"))
        XCTAssertTrue(scope.includes(path: "/scan/tree/a"))
        XCTAssertFalse(scope.includes(path: "/scan/treehouse/a"))
        XCTAssertFalse(scope.includes(path: "/scan"))
    }

    func testTrailingSlashesAreNormalized() {
        let scope = scope(root: "/scan/tree/")
        XCTAssertEqual(scope.rootPath, "/scan/tree")
        XCTAssertTrue(scope.includes(path: "/scan/tree/folder/"))
        XCTAssertTrue(scope.includes(path: "/scan/tree/folder"))
    }

    // MARK: - Exclusions

    func testExcludedSubtreeIsDropped() {
        let scope = scope(excluded: ["/scan/tree/cache"])
        XCTAssertFalse(scope.includes(path: "/scan/tree/cache"))
        XCTAssertFalse(scope.includes(path: "/scan/tree/cache/nested/file"))
        XCTAssertTrue(scope.includes(path: "/scan/tree/cache2/file"))
        XCTAssertTrue(scope.includes(path: "/scan/tree/other"))
    }

    func testExclusionAtOrAboveTheRootIsIgnored() {
        let scope = scope(excluded: ["/scan/tree", "/scan", "/"])
        XCTAssertTrue(scope.includes(path: "/scan/tree/file"))
        XCTAssertTrue(scope.includes(path: "/scan/tree/folder/file"))
    }

    // MARK: - Reducing a batch

    func testBatchReportsUniqueFoldersInOrder() throws {
        let scope = scope(excluded: ["/scan/tree/cache"])
        // FSEvents without item-level events names the directory that changed,
        // so a batch is already a list of folders.
        let change = scope.change(inBatch: [
            "/scan/tree/a",
            "/scan/tree/a/",
            "/scan/tree/b",
            "/elsewhere/c",
            "/scan/tree/cache",
        ])

        let result = try XCTUnwrap(change)
        XCTAssertEqual(result.folders.map(\.path), ["/scan/tree/a", "/scan/tree/b"])
        XCTAssertEqual(result.folderCount, 2)
        XCTAssertFalse(result.isCoarse)
        XCTAssertFalse(result.rootMissing)
    }

    func testBatchIsBoundedButCountsEveryFolder() throws {
        let paths = (0..<25).map { "/scan/tree/folder-\($0)/file" }
        let result = try XCTUnwrap(scope().change(inBatch: paths))
        XCTAssertEqual(result.folders.count, ScanWatchScope.maxReportedFolders)
        XCTAssertEqual(result.folderCount, 25, "a shortened list never claims to be the whole batch")
    }

    func testOutOfScopeBatchIsNil() {
        XCTAssertNil(scope().change(inBatch: ["/elsewhere/file", "/scan/treehouse/file"]))
    }

    func testCoarseBatchNamesTheRoot() throws {
        let scope = scope()
        let result = try XCTUnwrap(scope.change(inBatch: ["/scan/tree/a"], isCoarse: true))
        XCTAssertTrue(result.isCoarse)
        XCTAssertFalse(result.rootMissing)
        XCTAssertEqual(result.folders.map(\.path), ["/scan/tree"])
    }

    func testMissingRootIsReported() throws {
        let scope = scope()
        let result = try XCTUnwrap(scope.change(inBatch: [], rootMissing: true))
        XCTAssertTrue(result.rootMissing)
        XCTAssertEqual(result.folders.map(\.path), ["/scan/tree"])
    }

    // MARK: - The startup disk's data volume

    func testDataVolumePathsMapIntoTheRootNamespace() {
        let scope = scope(root: "/")
        XCTAssertTrue(scope.includes(path: "/System/Volumes/Data/Users/me/file"))
        XCTAssertEqual(
            scope.change(inBatch: ["/System/Volumes/Data/Users/me"])?.folders.map(\.path),
            ["/Users/me"]
        )
        XCTAssertEqual(
            scope.change(inBatch: ["/System/Volumes/Data"])?.folders.map(\.path),
            ["/"]
        )
    }

    func testDataVolumeMappingOnlyAppliesToTheRootVolume() {
        let scope = scope(root: "/Users")
        XCTAssertTrue(scope.includes(path: "/Users/me/file"))
        XCTAssertFalse(scope.includes(path: "/System/Volumes/Data/Users/me/file"))
    }

    // MARK: - Volume rule

    func testStayOnVolumeUsesTheScansOwnDeviceRule() {
        let probe = FakeProbe(devices: [
            "/scan/tree/local/file": dev_t(1),
            "/scan/tree/mounted/file": dev_t(2),
        ])
        let staying = scope(stayOnVolume: true, rootDevice: dev_t(1), probe: probe)
        XCTAssertTrue(staying.includes(path: "/scan/tree/local/file"))
        XCTAssertFalse(staying.includes(path: "/scan/tree/mounted/file"))

        let crossing = scope(stayOnVolume: false, rootDevice: dev_t(1), probe: probe)
        XCTAssertTrue(crossing.includes(path: "/scan/tree/mounted/file"))
    }

    func testAnUnreadableVolumeAnswerDoesNotHideAChange() {
        let scope = scope(stayOnVolume: true, rootDevice: dev_t(1), probe: FakeProbe())
        XCTAssertTrue(scope.includes(path: "/scan/tree/unknown/file"))
    }
}
