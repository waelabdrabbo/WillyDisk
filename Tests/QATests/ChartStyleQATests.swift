import XCTest
import DiskLocalization
@testable import DiskUI

/// Independent verification of the chart preference.
///
/// The choice is stored in `UserDefaults` and read back by both the Settings
/// window that offers it and the results screen that draws it, so this checks
/// the stored form, the round-trip, and the fallback — including the default,
/// which must stay the sunburst.
final class ChartStyleQATests: XCTestCase {

    func testEveryCaseRoundTripsThroughItsStoredValue() {
        for option in AppChartStyle.allCases {
            XCTAssertEqual(AppChartStyle(rawValue: option.rawValue), option,
                           "\(option.rawValue) must read back as the case that stored it")
        }
    }

    func testStoredPreferenceIsTheLastChoiceAndDefaultsToSunburst() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppChartStyle.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppChartStyle.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppChartStyle.defaultsKey)
            }
        }

        defaults.removeObject(forKey: AppChartStyle.defaultsKey)
        XCTAssertEqual(AppChartStyle.stored, .sunburst,
                       "nothing stored keeps the chart the app is known by")

        defaults.set(AppChartStyle.treemap.rawValue, forKey: AppChartStyle.defaultsKey)
        XCTAssertEqual(AppChartStyle.stored, .treemap)

        defaults.set("pie", forKey: AppChartStyle.defaultsKey)
        XCTAssertEqual(AppChartStyle.stored, .sunburst,
                       "an unreadable value must not leave the chart unset")
    }

    func testChoicesAreDistinctlyLabelled() {
        let labels = Set(AppChartStyle.allCases.map(\.label))
        XCTAssertEqual(labels.count, AppChartStyle.allCases.count)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }

    func testBothChoicesAreTranslated() {
        for option in AppChartStyle.allCases {
            let arabic = L10n.string(option.label, language: "ar")
            XCTAssertNotEqual(arabic, option.label,
                              "\(option.rawValue) has no Arabic name")
        }
    }
}
