import XCTest
import DiskLocalization
@testable import DiskUI

/// The Settings language preference: what it pins, how the two endonyms read,
/// and how a stored choice is recovered before the app builds a window.
final class AppLanguageQATests: XCTestCase {

    override func tearDown() {
        L10n.overrideLanguage(nil)
        super.tearDown()
    }

    func testChoicesMapToTheCatalogLanguages() {
        XCTAssertEqual(AppLanguage.allCases, [.system, .english, .arabic])
        XCTAssertNil(AppLanguage.system.catalogLanguage)
        XCTAssertEqual(AppLanguage.english.catalogLanguage, "en")
        XCTAssertEqual(AppLanguage.arabic.catalogLanguage, "ar")
    }

    func testArabicAppliesImmediately() {
        AppLanguage.arabic.apply()
        XCTAssertEqual(L10n.language, "ar")
        XCTAssertTrue(L10n.isRightToLeft)
        XCTAssertEqual(L10n.string("Language"), "اللغة")
        XCTAssertEqual(L10n.string("Changes the interface language right away."), "يغيّر لغة الواجهة فورًا.")
    }

    func testEnglishAppliesImmediately() {
        AppLanguage.arabic.apply()
        AppLanguage.english.apply()
        XCTAssertEqual(L10n.language, "en")
        XCTAssertFalse(L10n.isRightToLeft)
        XCTAssertEqual(L10n.string("Language"), "Language")
    }

    func testEndonymsStayReadableInEitherLanguage() {
        L10n.overrideLanguage("en")
        XCTAssertEqual(AppLanguage.system.label, "System")
        XCTAssertEqual(AppLanguage.english.label, "English")
        XCTAssertEqual(AppLanguage.arabic.label, "العربية")

        L10n.overrideLanguage("ar")
        XCTAssertEqual(AppLanguage.system.label, "النظام")
        XCTAssertEqual(AppLanguage.english.label, "English", "a language keeps its own name")
        XCTAssertEqual(AppLanguage.arabic.label, "العربية")
    }

    func testStoredPreferenceFallsBackToSystem() {
        let suite = "AppLanguageQATests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppLanguage.stored(in: defaults), .system, "no choice follows the system")
        defaults.set(AppLanguage.arabic.rawValue, forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.stored(in: defaults), .arabic)
        defaults.set("klingon", forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.stored(in: defaults), .system, "an unknown value follows the system")
    }

    func testApplyStoredPinsTheLanguageBeforeTheWindow() {
        let suite = "AppLanguageQATests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(AppLanguage.arabic.rawValue, forKey: AppLanguage.defaultsKey)
        AppLanguage.applyStored(in: defaults)
        XCTAssertEqual(L10n.language, "ar")
        XCTAssertEqual(L10n.string("Language"), "اللغة")
    }
}
