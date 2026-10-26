import XCTest
import Foundation
import DiskCLI
import DiskCore
import DiskUI
@testable import DiskLocalization

/// Enforces the localization rules over the source tree: no user-visible literal
/// stands outside the catalog, every catalog key is used, and every key a view
/// names exists in the catalog.
final class LocalizationGuardQATests: XCTestCase {

    private static var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var sourceRoots: [URL] {
        ["DiskUI", "WillyDiskApp", "DiskCLI"].map {
            repository.appendingPathComponent("Sources/\($0)")
        }
    }

    private static var catalog: [String: Any] {
        let url = repository.appendingPathComponent("Sources/DiskLocalization/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = object["strings"] as? [String: Any] else {
            XCTFail("the string catalog could not be read at \(url.path)")
            return [:]
        }
        return strings
    }

    private static func swiftFiles() -> [URL] {
        var files: [URL] = []
        for root in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Sources with comments removed, so an example in a comment never counts.
    private static func code(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix("//") { return "" }
                return line
            }
            .joined(separator: "\n")
    }

    private static func decode(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            guard character == "\\", raw.index(after: index) < raw.endIndex else {
                output.append(character)
                index = raw.index(after: index)
                continue
            }
            let escape = raw[raw.index(after: index)]
            index = raw.index(index, offsetBy: 2)
            switch escape {
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "r": output.append("\r")
            case "\"": output.append("\"")
            case "\\": output.append("\\")
            case "u":
                guard raw[index] == "{",
                      let end = raw[index...].firstIndex(of: "}") else { continue }
                let digits = raw[raw.index(after: index)..<end]
                if let scalar = UInt32(digits, radix: 16), let value = Unicode.Scalar(scalar) {
                    output.append(Character(value))
                }
                index = raw.index(after: end)
            default:
                output.append(escape)
            }
        }
        return output
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    private static let userVisiblePatterns = [
        #"\b(Text|Label|Button|Toggle|Picker|TextField|SecureField|Section|Menu|TableColumn|Window|CommandMenu|ContentUnavailableView)\(\s*""#,
        #"\.(help|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle)\(\s*""#,
        #"\b(alert|confirmationDialog)\(\s*""#,
        #"\b(messageText|informativeText)\s*=\s*""#,
        #"\.(prompt|message)\s*=\s*""#,
    ]

    func testNoUserVisibleLiteralSitsOutsideTheCatalog() {
        for file in Self.swiftFiles() {
            let code = Self.code(of: file)
            for pattern in Self.userVisiblePatterns {
                let matches = Self.matches(pattern, in: code)
                XCTAssertTrue(
                    matches.isEmpty,
                    "\(file.lastPathComponent) passes a literal to a user-visible control: \(matches.prefix(3).map { $0[0] })"
                )
            }
        }
    }

    func testEveryKeyUsedInSourceIsInTheCatalog() {
        let catalog = Self.catalog
        let pattern = #"L10n\.(?:string|format)\(\s*(?:[^"()]*?\?\s*)?"((?:[^"\\]|\\.)*)"(?:\s*:\s*"((?:[^"\\]|\\.)*)")?"#
        for file in Self.swiftFiles() {
            for match in Self.matches(pattern, in: Self.code(of: file)) {
                for group in match.dropFirst() where !group.isEmpty {
                    let key = Self.decode(group)
                    XCTAssertNotNil(catalog[key], "\(file.lastPathComponent) uses a key the catalog does not carry: \(key.debugDescription)")
                }
            }
        }
        XCTAssertNotNil(catalog[ScanCommandLine.helpKey], "the CLI help text is not in the catalog")
    }

    func testEveryCatalogKeyIsUsed() {
        var used = Set<String>()
        let literal = #""((?:[^"\\]|\\.)*)""#
        for file in Self.swiftFiles() {
            for match in Self.matches(literal, in: Self.code(of: file)) where match.count > 1 {
                used.insert(Self.decode(match[1]))
            }
        }
        used.insert(ScanCommandLine.helpKey)
        used.insert(CleanupCommandLine.helpKey)
        let unused = Set(Self.catalog.keys).subtracting(used)
        XCTAssertTrue(unused.isEmpty, "catalog keys with no call site: \(unused.sorted())")
    }

    func testEveryPresetNameIsTranslated() {
        for preset in ScanPresetCatalog.candidates {
            let arabic = L10n.string(preset.name, language: "ar")
            XCTAssertNotEqual(arabic, preset.name, "preset \(preset.name) has no Arabic name")
        }
    }

    func testCLICategoryNamesAreTranslated() {
        for category in FileCategory.allCases {
            let key = category.rawValue.capitalized
            XCTAssertNotEqual(
                L10n.string(key, language: "ar"),
                key,
                "the CLI prints \(key) as a category name"
            )
        }
    }

    func testCLIHelpIsCataloguedAndFillsItsDefaults() {
        let key = ScanCommandLine.helpKey
        XCTAssertEqual(L10n.string(key, language: "en"), key)
        XCTAssertNotEqual(L10n.string(key, language: "ar"), key)
        let english = L10n.format(
            key,
            language: "en",
            arguments: [ScanCommand.defaultDepth, ScanCommand.defaultTop, ScanRecord.currentSchemaVersion]
        )
        XCTAssertTrue(english.contains("Default: 2."), english)
        XCTAssertTrue(english.contains("Default: 10."), english)
        XCTAssertTrue(english.contains("(schema 1)"), english)

        let arabic = L10n.format(
            key,
            language: "ar",
            arguments: [ScanCommand.defaultDepth, ScanCommand.defaultTop, ScanRecord.currentSchemaVersion]
        )
        XCTAssertTrue(arabic.contains("الاستخدام"), arabic)
        XCTAssertTrue(arabic.contains("2."), arabic)
        XCTAssertTrue(arabic.contains("10."), arabic)
        XCTAssertTrue(arabic.contains("المخطط 1"), arabic)
    }
}
