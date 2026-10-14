import XCTest
import AppKit
@testable import DiskUI

/// Independent verification of the app's appearance preference.
///
/// The choice is persisted and then applied as the app object's appearance, so
/// this checks the stored form, the stored-value round-trip, and the mapping —
/// including `system`, which must hand the decision back rather than pin one of
/// the two appearances.
final class AppearanceQATests: XCTestCase {

    func testEveryCaseRoundTripsThroughItsStoredValue() {
        for option in AppAppearance.allCases {
            XCTAssertEqual(AppAppearance(rawValue: option.rawValue), option,
                           "\(option.rawValue) must read back as the case that stored it")
        }
    }

    func testAppearanceMatchesTheChosenCase() {
        XCTAssertNil(AppAppearance.system.nsAppearance,
                     "system must leave the app following the system appearance")
        XCTAssertEqual(AppAppearance.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.nsAppearance?.name, .darkAqua)
    }

    func testStoredPreferenceIsTheLastChoiceAndDefaultsToSystem() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppAppearance.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppAppearance.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppAppearance.defaultsKey)
            }
        }

        defaults.removeObject(forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored, .system, "nothing stored is the system's decision")

        defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored, .dark)

        defaults.set("chartreuse", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored, .system, "an unreadable value must not pin an appearance")
    }

    func testChoicesAreDistinctlyLabelledAndSymbolised() {
        let labels = Set(AppAppearance.allCases.map(\.label))
        let symbols = Set(AppAppearance.allCases.map(\.symbolName))
        XCTAssertEqual(labels.count, AppAppearance.allCases.count)
        XCTAssertEqual(symbols.count, AppAppearance.allCases.count)
    }
}
