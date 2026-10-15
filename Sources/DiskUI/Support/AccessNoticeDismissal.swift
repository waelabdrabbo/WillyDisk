import Foundation

/// Persists whether the user dismissed the restricted-locations notice.
///
/// One flag, remembered across scans and launches: once the restricted
/// locations have been explained, the notice stops taking footer space until
/// the user reopens it from the footer's count chip. Mirrors the
/// `RecentLocations` pattern — a tiny, app-owned `UserDefaults` key.
enum AccessNoticeDismissal {
    private static let key = "WillyDisk.AccessNoticeDismissed"

    static var isDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
