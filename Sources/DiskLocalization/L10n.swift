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
/// process's preferences.
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
        let fallback = table(for: sourceLanguage)
        return fallback.localizedString(forKey: key, value: key, table: catalogTable)
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

    private static var bundledLanguages: [String] {
        Bundle.module.localizations.sorted()
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
        let module = Bundle.module
        let bundle: Bundle
        if let path = module.path(forResource: language, ofType: "lproj"),
           let localized = Bundle(path: path) {
            bundle = localized
        } else {
            bundle = module
        }
        tables[language] = bundle
        return bundle
    }
}
