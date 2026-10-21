import SwiftUI

/// The results actions the menu bar can invoke.
///
/// The toolbar buttons and the menu items call the same closures, so a command
/// can never drift from the control it mirrors. The value is supplied by
/// `ResultsView` for as long as that screen is the active scene content.
public struct ResultsCommands {
    public var canRescan: Bool
    public var rescan: () -> Void
    public var canExport: Bool
    public var exportJSON: () -> Void
    public var exportCSV: () -> Void
    public var canShowCoverage: Bool
    public var showCoverage: () -> Void
    public var canShowCleanup: Bool
    public var showCleanup: () -> Void
    public var canShowHistory: Bool
    public var showHistory: () -> Void
    public var focusSearch: () -> Void

    public init(
        canRescan: Bool,
        rescan: @escaping () -> Void,
        canExport: Bool,
        exportJSON: @escaping () -> Void,
        exportCSV: @escaping () -> Void,
        canShowCoverage: Bool,
        showCoverage: @escaping () -> Void,
        canShowCleanup: Bool,
        showCleanup: @escaping () -> Void,
        canShowHistory: Bool,
        showHistory: @escaping () -> Void,
        focusSearch: @escaping () -> Void
    ) {
        self.canRescan = canRescan
        self.rescan = rescan
        self.canExport = canExport
        self.exportJSON = exportJSON
        self.exportCSV = exportCSV
        self.canShowCoverage = canShowCoverage
        self.showCoverage = showCoverage
        self.canShowCleanup = canShowCleanup
        self.showCleanup = showCleanup
        self.canShowHistory = canShowHistory
        self.showHistory = showHistory
        self.focusSearch = focusSearch
    }
}

/// The scan actions every screen can invoke: cancelling the one running scan.
public struct ScanCommands {
    public var canCancel: Bool
    public var cancel: () -> Void

    public init(canCancel: Bool, cancel: @escaping () -> Void) {
        self.canCancel = canCancel
        self.cancel = cancel
    }
}

private struct ResultsCommandsKey: FocusedValueKey {
    typealias Value = ResultsCommands
}

private struct ScanCommandsKey: FocusedValueKey {
    typealias Value = ScanCommands
}

public extension FocusedValues {
    var resultsCommands: ResultsCommands? {
        get { self[ResultsCommandsKey.self] }
        set { self[ResultsCommandsKey.self] = newValue }
    }

    var scanCommands: ScanCommands? {
        get { self[ScanCommandsKey.self] }
        set { self[ScanCommandsKey.self] = newValue }
    }
}
