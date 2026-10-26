import Foundation

/// Where a SwiftPM resource bundle lives at run time.
///
/// SwiftPM generates a `Bundle.module` accessor that answers from exactly two
/// places: the directory `Bundle.main.bundleURL` names, and the absolute build
/// path the module was compiled under. Inside an app bundle the first is the
/// `.app` itself — not `Contents/Resources`, where macOS expects resources and
/// where `Scripts/bundle-app.sh` puts them — and the second only exists on the
/// machine that built it. An installed app therefore cannot reach its own
/// strings or its mark through that accessor.
///
/// This lookup asks the layouts WillyDisk actually runs in, app bundle first, so
/// the same code loads resources from a build tree and from `/Applications`.
public enum BundledResources {
    /// The bundle named `<name>.bundle`, from the first layout that has it, or
    /// `nil` when no layout does.
    ///
    /// - Parameters:
    ///   - name: the bundle's name without its extension, which SwiftPM forms as
    ///     `<package>_<target>`, e.g. `WillyDisk_DiskLocalization`.
    ///   - main: the bundle to search from. Production passes `.main`; a test
    ///     passes the fake app it built so the app layout can be checked
    ///     without assembling one.
    public static func locate(_ name: String, in main: Bundle = .main) -> Bundle? {
        for directory in searchDirectories(for: main) {
            let candidate = directory.appendingPathComponent(name)
                .appendingPathExtension("bundle")
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }

    /// Every directory a resource bundle may sit in, in the order `locate` tries
    /// them. Reported when a lookup fails, so the failure names what it checked.
    public static func searchDirectories(for main: Bundle = .main) -> [URL] {
        var directories: [URL] = []
        var seen = Set<String>()
        func append(_ url: URL?) {
            guard let url else { return }
            // `resourceURL` and `bundleURL` are the same directory for a plain
            // executable; reporting it twice would only lengthen the failure.
            if seen.insert(url.standardizedFileURL.path).inserted {
                directories.append(url)
            }
        }

        // An app bundle: Contents/Resources.
        append(main.resourceURL)
        // SwiftPM's layout for a plain executable: the bundle beside the binary.
        append(main.bundleURL)
        append(main.executableURL?.deletingLastPathComponent())
        // A test bundle: SwiftPM writes the packages' resource bundles beside it.
        let code = Bundle(for: CodeBundleFinder.self)
        append(code.resourceURL)
        append(code.bundleURL.deletingLastPathComponent())
        return directories
    }

    /// The bundle paths `locate` would try, for a failure that says where it
    /// looked.
    public static func attemptedPaths(_ name: String, in main: Bundle = .main) -> [String] {
        searchDirectories(for: main).map {
            $0.appendingPathComponent(name).appendingPathExtension("bundle").path
        }
    }
}

/// A class whose bundle is the one this code was linked into, which is how the
/// search reaches `PackageTests.xctest` under `swift test`.
private final class CodeBundleFinder {}
