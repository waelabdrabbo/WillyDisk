import Foundation

/// The app's one path to user-visible text.
///
/// Every string the interface shows is looked up here from
/// `Localizable.xcstrings`, keyed by its English source. The key is the English
/// text with `%@` and `%lld` placeholders where a value is substituted, so a key
/// can be read from the source and the catalog entry that serves it is obvious.
/// `Scripts/localize.sh` compiles the catalog into the `.lproj` tables this
/// lookup reads; the catalog itself is not a resource.
///
/// Language is resolved explicitly instead of asking `Bundle.localizedString`
/// to choose one. A Swift Package's resource bundle is not the main bundle, and
/// Foundation picks a bundle's localization from the process's main bundle — the
/// choice collapses to the development language outside an app. Resolving the
/// `.lproj` here keeps the same lookup working in the app, the offscreen renderer,
/// and the tests, and lets a render ask for one language without changing the
/// process's preferences. A bundled language Foundation will not localize is
/// read from its table file instead, so it never silently answers in English.
public enum L10n {

    /// A language the catalog carries. English is the source and the fallback.
    public static var availableLanguages: [String] {
        bundledLanguages
    }

    /// The language lookups use right now. An explicit override wins; otherwise
    /// the first preferred language the catalog can serve, else English.
    public static var language: String {
        lock.lock()
        defer { lock.unlock() }
        if let languageOverrideValue { return languageOverrideValue }
        if let resolved { return resolved }
        let language = resolvePreferredLanguage()
        resolved = language
        return language
    }

    /// The locale a language formats numbers, dates, and plurals with.
    public static var locale: Locale {
        Locale(identifier: language)
    }

    /// Whether the interface language is written right to left.
    public static var isRightToLeft: Bool {
        Locale.Language(identifier: language).characterDirection == .rightToLeft
    }

    /// Pins every lookup to one language, or restores system resolution with
    /// `nil`. The offscreen renderer sets this before it builds a view; tests
    /// use it to assert wording without depending on the host's language.
    public static func overrideLanguage(_ language: String?) {
        lock.lock()
        defer { lock.unlock() }
        languageOverrideValue = language
        resolved = nil
    }

    /// The localized text for a key. A key with no entry in the chosen language
    /// falls back to the English source, then to the key itself.
    public static func string(_ key: String) -> String {
        string(key, language: language)
    }

    /// The localized text for a key, formatted with the chosen language's
    /// plural rules. Plural nouns live in the catalog as variations of the key,
    /// so a count is never glued to a noun by hand.
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, language: language, arguments)
    }

    /// Joins phrases the way the interface language lists them: “A, B, and C”
    /// in English, “A وB وC” in Arabic. Used for spoken summaries whose parts
    /// are built from measurements rather than written as one sentence.
    public static func list(_ items: [String]) -> String {
        guard let first = items.first else { return "" }
        guard items.count > 1 else { return first }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }

    public static func string(_ key: String, language: String) -> String {
        let chosen = table(for: language)
        let value = chosen.localizedString(forKey: key, value: nil, table: catalogTable)
        if value != key { return value }
        // `Bundle` serves a language it recognises in the bundle. A table it
        // will not serve is read from the file SwiftPM copied, so a language
        // bundled beside it still answers.
        if let value = directValue(for: key, language: language) { return value }
        let fallback = table(for: sourceLanguage)
        let fallbackValue = fallback.localizedString(forKey: key, value: nil, table: catalogTable)
        if fallbackValue != key { return fallbackValue }
        return directValue(for: key, language: sourceLanguage) ?? key
    }

    public static func format(_ key: String, language: String, _ arguments: CVarArg...) -> String {
        format(key, language: language, arguments: arguments)
    }

    /// The array form, for callers that already hold their arguments.
    public static func format(_ key: String, language: String, arguments: [CVarArg]) -> String {
        let format = string(key, language: language)
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }

    // MARK: - Internals

    /// The catalog's table name, without its extension. It is the default
    /// `Localizable` table so the catalog follows the platform convention.
    private static let catalogTable = "Localizable"

    /// The language a key is written in.
    private static let sourceLanguage = "en"

    private static let lock = NSLock()

    nonisolated(unsafe) private static var languageOverrideValue: String?

    nonisolated(unsafe) private static var resolved: String?

    nonisolated(unsafe) private static var tables: [String: Bundle] = [:]

    /// Values read straight from a language's compiled table, for the tables
    /// `Bundle` will not localize.
    nonisolated(unsafe) private static var directTables: [String: [String: String]] = [:]

    /// Every language the resource bundle carries: the localizations Foundation
    /// recognizes, plus the `.lproj` directories SwiftPM copied, each under the
    /// catalog's spelling.
    private static var bundledLanguages: [String] {
        var languages = Set(Bundle.module.localizations.map(canonicalLanguage))
        for directory in localizationDirectories {
            for entry in localizationEntries(in: directory) {
                languages.insert(canonicalLanguage(entry.deletingPathExtension().lastPathComponent))
            }
        }
        return languages.sorted()
    }

    private static func resolvePreferredLanguage() -> String {
        let available = bundledLanguages
        let preferred = Bundle.preferredLocalizations(
            from: available,
            forPreferences: Locale.preferredLanguages
        )
        if let match = preferred.first(where: { available.contains($0) }) {
            return match
        }
        return available.contains(sourceLanguage) ? sourceLanguage : available.first ?? sourceLanguage
    }

    /// The `.lproj` bundle for a language, or the source bundle when the catalog
    /// has no folder for it.
    private static func table(for language: String) -> Bundle {
        lock.lock()
        defer { lock.unlock() }
        if let cached = tables[language] { return cached }
        let bundle: Bundle
        if let directory = localizationDirectory(for: language),
           let localized = Bundle(path: directory.path) {
            bundle = localized
        } else {
            bundle = Bundle.module
        }
        tables[language] = bundle
        return bundle
    }

    /// The language's compiled table, read from its file. The caller holds
    /// `lock`.
    ///
    /// A plural key has no plain entry here; its variations stay with the
    /// `.stringsdict` the bundle resolves.
    private static func directTable(for language: String) -> [String: String] {
        if let cached = directTables[language] { return cached }
        var values: [String: String] = [:]
        if let directory = localizationDirectory(for: language) {
            let file = directory.appendingPathComponent("\(catalogTable).strings")
            if let data = try? Data(contentsOf: file),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let table = plist as? [String: Any] {
                values = table.compactMapValues { $0 as? String }
            }
        }
        directTables[language] = values
        return values
    }

    private static func directValue(for key: String, language: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return directTable(for: language)[key]
    }

    /// The values the compiled table for a language carries, read from the file
    /// SwiftPM copied. The QA suite checks a language this way because the
    /// lookup itself can be answered by `Bundle` instead.
    static func bundledTable(_ language: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return directTable(for: language)
    }

    /// The bundled directory for a language.
    ///
    /// `Bundle.path(forResource:ofType:)` is the direct route, but Foundation
    /// only answers it for localizations it recognises. The directories SwiftPM
    /// copied are searched too, and their names compared without case or
    /// separator differences, so a language the system does not list is still
    /// found. The caller holds `lock`.
    private static func localizationDirectory(for language: String) -> URL? {
        let module = Bundle.module
        if let path = module.path(forResource: language, ofType: "lproj") {
            return URL(fileURLWithPath: path)
        }
        let wanted = normalizedLanguage(language)
        for directory in localizationDirectories {
            for entry in localizationEntries(in: directory)
            where normalizedLanguage(entry.deletingPathExtension().lastPathComponent) == wanted {
                return entry
            }
        }
        return nil
    }

    /// The directories a SwiftPM resource bundle may keep its `.lproj` folders
    /// in. `resourceURL` is the usual answer; the bundle's own layout is asked
    /// too, so a bundle that does not report one is still searched.
    private static var localizationDirectories: [URL] {
        let module = Bundle.module
        var directories: [URL] = []
        if let resources = module.resourceURL { directories.append(resources) }
        directories.append(module.bundleURL.appendingPathComponent("Contents/Resources"))
        directories.append(module.bundleURL)
        return directories
    }

    private static func localizationEntries(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.filter { $0.pathExtension.lowercased() == "lproj" }
    }

    /// A language identifier compared without case or separator differences, so
    /// `en-XA` and `en_xa` name the same directory.
    private static func normalizedLanguage(_ language: String) -> String {
        language.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// A language name as the catalog spells it: `en`, `ar`, `en-XA`.
    ///
    /// A bundle may copy a localization directory under the system's spelling —
    /// `en_XA` or `en-xa` — while the app asks for the catalog's. The language
    /// is lowercased, a two-letter region uppercased, a four-letter script
    /// titlecased, and the parts joined with hyphens.
    private static func canonicalLanguage(_ name: String) -> String {
        let parts = name.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let language = parts.first, !language.isEmpty else { return name }
        var canonical = [language.lowercased()]
        for part in parts.dropFirst() {
            switch part.count {
            case 2:
                canonical.append(part.uppercased())
            case 4:
                canonical.append(part.prefix(1).uppercased() + part.dropFirst().lowercased())
            default:
                canonical.append(part.lowercased())
            }
        }
        return canonical.joined(separator: "-")
    }
}
