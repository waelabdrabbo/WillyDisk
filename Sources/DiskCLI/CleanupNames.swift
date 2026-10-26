import DiskCore
import DiskLocalization

/// The rule and tier names the command line prints.
///
/// The rules themselves are `DiskCore`'s and carry no strings. The app's copy of
/// these names lives beside its sheet; this one exists because the command line
/// links `DiskCore` and `DiskLocalization`, never the UI. Both read the same
/// catalog keys, so a translation changes both at once.
extension CleanupRule {
    var title: String {
        switch self {
        case .caches: L10n.string("Caches")
        case .developerSupport: L10n.string("Device support")
        case .simulators: L10n.string("Simulators")
        case .logs: L10n.string("Logs")
        case .downloads: L10n.string("Old downloads")
        case .largeAndOld: L10n.string("Large and old")
        }
    }
}

extension CleanupTier {
    var title: String {
        switch self {
        case .rebuildable: L10n.string("Rebuildable")
        case .personal: L10n.string("Your files")
        }
    }
}
