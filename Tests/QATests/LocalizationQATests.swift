import XCTest
import Foundation
@testable import DiskLocalization

/// The catalog and the lookup path, checked independently of any view.
final class LocalizationQATests: XCTestCase {

    private struct Catalog {
        var strings: [String: [String: Any]]
    }

    private static var catalog: Catalog {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent() // QATests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
        let url = root.appendingPathComponent("Sources/DiskLocalization/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = object["strings"] as? [String: [String: Any]] else {
            XCTFail("the string catalog could not be read at \(url.path)")
            return Catalog(strings: [:])
        }
        return Catalog(strings: strings)
    }

    private static let formatSpecifier = try! NSRegularExpression(
        pattern: #"%(?:%|[-+ 0#']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF])"#
    )

    private static func specifiers(in value: String) -> [String] {
        let range = NSRange(value.startIndex..., in: value)
        return formatSpecifier.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            let token = String(value[range])
            return token == "%%" ? nil : token
        }
    }

    private static func stringUnit(_ localization: [String: Any]) -> String? {
        (localization["stringUnit"] as? [String: Any])?["value"] as? String
    }

    private static func pluralUnits(_ localization: [String: Any]) -> [String: String]? {
        guard let variations = localization["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any] else { return nil }
        var units: [String: String] = [:]
        for (category, raw) in plural {
            guard let entry = raw as? [String: Any], let value = stringUnit(entry) else { return nil }
            units[category] = value
        }
        return units
    }

    func testCatalogCarriesEveryLanguageAndPlaceholder() {
        let catalog = Self.catalog
        XCTAssertGreaterThan(catalog.strings.count, 500, "the catalog must cover the whole interface")

        for (key, entry) in catalog.strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in ["en", "ar", "en-XA"] {
                XCTAssertNotNil(localizations[language], "\(language) is missing for \(key.debugDescription)")
            }
            let english = localizations["en"].flatMap(Self.stringUnit)
                ?? localizations["en"].flatMap(Self.pluralUnits).map { $0["other"] ?? "" }
            let arabic = localizations["ar"].flatMap(Self.stringUnit)
                ?? localizations["ar"].flatMap(Self.pluralUnits).map { $0["other"] ?? "" }
            guard let english, let arabic else {
                XCTFail("\(key.debugDescription) has no plain value")
                continue
            }
            if let units = localizations["ar"].flatMap(Self.pluralUnits) {
                for (category, value) in units {
                    let expected = Self.specifiers(in: english).filter { $0 != "%lld" }
                    let actual = Self.specifiers(in: value).filter { $0 != "%lld" }
                    XCTAssertEqual(actual, expected, "\(key.debugDescription) [ar.\(category)] changes placeholders")
                }
            } else {
                XCTAssertEqual(
                    Self.specifiers(in: arabic),
                    Self.specifiers(in: english),
                    "\(key.debugDescription) changes placeholders in Arabic"
                )
            }
            if let units = localizations["en-XA"].flatMap(Self.pluralUnits) {
                for (category, value) in units {
                    XCTAssertEqual(
                        Self.specifiers(in: value).filter { $0 != "%lld" },
                        Self.specifiers(in: english).filter { $0 != "%lld" },
                        "\(key.debugDescription) [en-XA.\(category)] changes placeholders"
                    )
                }
            } else if let pseudo = localizations["en-XA"].flatMap(Self.stringUnit) {
                XCTAssertEqual(
                    Self.specifiers(in: pseudo),
                    Self.specifiers(in: english),
                    "\(key.debugDescription) changes placeholders in the pseudolanguage"
                )
            }
        }
    }

    func testPlainLookupUsesTheRequestedLanguage() {
        XCTAssertEqual(L10n.string("Files", language: "en"), "Files")
        XCTAssertEqual(L10n.string("Files", language: "ar"), "الملفات")
        XCTAssertEqual(L10n.string("Files", language: "fr"), "Files", "an unsupported language falls back to English")
    }

    func testArabicPluralCategoriesResolve() {
        func files(_ count: Int) -> String {
            L10n.format("%lld files", language: "ar", arguments: [count])
        }
        XCTAssertEqual(files(0), "لا ملفات")
        XCTAssertEqual(files(1), "ملف واحد")
        XCTAssertEqual(files(2), "ملفان")
        XCTAssertEqual(files(3), "3 ملفات")
        XCTAssertEqual(files(11), "11 ملفًا")
        XCTAssertEqual(files(100), "100 ملف")
    }

    func testPseudolanguageKeepsFormatAndDoublesTheText() {
        let english = L10n.string("Search this scan", language: "en")
        let pseudo = L10n.string("Search this scan", language: "en-XA")
        XCTAssertNotEqual(
            pseudo,
            english,
            "the pseudolanguage answered in English; offered languages: \(L10n.availableLanguages)"
        )
        XCTAssertGreaterThan(pseudo.count, english.count + 4)
        XCTAssertTrue(pseudo.hasPrefix("["))
    }

    func testEveryBundledLanguageCarriesItsTable() {
        for language in ["en", "ar", "en-XA"] {
            let table = L10n.bundledTable(language)
            XCTAssertGreaterThan(table.count, 500, "\(language) has no readable table in the bundle")
            XCTAssertTrue(
                L10n.availableLanguages.contains(language),
                "\(language) is not offered; offered: \(L10n.availableLanguages)"
            )
        }
        let pseudo = L10n.bundledTable("en-XA")["Search this scan"]
        XCTAssertNotNil(pseudo, "the pseudolanguage table has no entry for the search field")
        XCTAssertTrue(pseudo?.hasPrefix("[") ?? false, "the pseudolanguage entry is not the generated one")
    }

    func testLanguageOverrideIsHonouredAndRestorable() {
        L10n.overrideLanguage("ar")
        defer { L10n.overrideLanguage(nil) }
        XCTAssertEqual(L10n.language, "ar")
        XCTAssertTrue(L10n.isRightToLeft)
        XCTAssertEqual(L10n.string("Home"), "الرئيسية")
        XCTAssertEqual(L10n.string("Files"), "الملفات")
    }
}
