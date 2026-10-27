import Foundation

/// The running app, reduced to the facts an update decision needs.
///
/// Reading the bundle here keeps `UpdateEvaluator` and `UpdateVerifier` free of
/// global state and lets tests describe a build without launching one. A bare
/// executable built by `swift run` has no marketing version and yields `nil`,
/// which the controller treats as "this build cannot compare itself to a release".
public struct InstalledBuild: Sendable {
    public let marketingVersion: String
    public let version: ReleaseVersion
    public let bundleIdentifier: String
    public let architecture: ReleaseArchitecture
    public let operatingSystemVersion: OperatingSystemVersion

    public init(
        marketingVersion: String,
        version: ReleaseVersion,
        bundleIdentifier: String,
        architecture: ReleaseArchitecture,
        operatingSystemVersion: OperatingSystemVersion
    ) {
        self.marketingVersion = marketingVersion
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.architecture = architecture
        self.operatingSystemVersion = operatingSystemVersion
    }

    /// The app bundle that is running, or `nil` when it is not an app bundle or
    /// its version cannot be read.
    public static func current(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> InstalledBuild? {
        guard let identifier = bundle.bundleIdentifier,
              let marketingVersion = bundle.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let version = ReleaseVersion(marketingVersion) else {
            return nil
        }
        return InstalledBuild(
            marketingVersion: marketingVersion,
            version: version,
            bundleIdentifier: identifier,
            architecture: .current,
            operatingSystemVersion: processInfo.operatingSystemVersion
        )
    }
}
