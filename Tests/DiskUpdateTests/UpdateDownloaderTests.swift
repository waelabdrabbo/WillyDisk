import XCTest
@testable import DiskUpdate

/// The download progress value and its ceiling, without a socket.
final class UpdateDownloaderTests: XCTestCase {
    func testFractionIsNilWithoutAnExpectedLength() {
        XCTAssertNil(DownloadProgress(receivedBytes: 100, expectedBytes: nil).fraction)
        XCTAssertNil(DownloadProgress(receivedBytes: 100, expectedBytes: 0).fraction)
    }

    func testFractionIsClampedToTheWholeRange() {
        let half = DownloadProgress(receivedBytes: 50, expectedBytes: 100)
        XCTAssertEqual(half.fraction, 0.5)

        let over = DownloadProgress(receivedBytes: 200, expectedBytes: 100)
        XCTAssertEqual(over.fraction, 1)

        let negative = DownloadProgress(receivedBytes: -1, expectedBytes: 100)
        XCTAssertEqual(negative.fraction, 0)
    }

    func testZeroIsIndeterminate() {
        XCTAssertEqual(DownloadProgress.zero.receivedBytes, 0)
        XCTAssertNil(DownloadProgress.zero.expectedBytes)
        XCTAssertNil(DownloadProgress.zero.fraction)
    }

    func testTheCeilingIsAboveARealRelease() {
        XCTAssertGreaterThan(URLSessionUpdateDownloader.maximumBytes, 3_000_000)
    }
}
