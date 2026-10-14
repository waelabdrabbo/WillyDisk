import XCTest
import DiskCore

/// Smoke test that the `DiskCoreTests` target resolves and that the frozen
/// `FileCategory` vocabulary is intact.
final class ContractSmokeTests: XCTestCase {
    func testFileCategoryHasAllCases() {
        XCTAssertEqual(FileCategory.allCases.count, 9)
    }
}
