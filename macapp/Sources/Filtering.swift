import AppKit

/// Status filter rows in the sidebar, mirroring the legacy app's `frow*` set
/// (`filtering.pas`) with native names.
enum StatusFilter: String, CaseIterable, Sendable {
    case all, downloading, completed, active, inactive, stopped, error, waiting

    var displayName: String {
        switch self {
        case .all: return "All"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .stopped: return "Stopped"
        case .error: return "Error"
        case .waiting: return "Waiting"
        }
    }

    /// SF Symbol name for the sidebar row.
    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .active: return "bolt.circle"
        case .inactive: return "pause.circle"
        case .stopped: return "stop.circle"
        case .error: return "exclamationmark.triangle"
        case .waiting: return "clock"
        }
    }

    /// State color for the sidebar row icon, kept consistent with
    /// `progressColor(for:)` in `MainWindowController`.
    var color: NSColor {
        switch self {
        case .all: return .secondaryLabelColor
        case .downloading: return .controlAccentColor
        case .completed: return .systemGreen
        case .active: return .systemPurple
        case .waiting: return .systemOrange
        case .error: return .systemRed
        case .stopped: return .systemYellow
        case .inactive: return .systemGray
        }
    }

    /// Mirrors `MatchSingleStateFilter` in `filtering.pas`.
    func matches(_ t: Torrent) -> Bool {
        switch self {
        case .all:
            return true
        case .downloading:
            return t.status == .downloading
        case .completed:
            return t.percentDone >= 1 || t.status == .seeding
        case .active:
            return t.status.isActive && t.isTransferring
        case .inactive:
            return !(t.status.isActive && t.isTransferring)
                && t.status != .stopped && t.percentDone < 1
        case .stopped:
            return t.status == .stopped
        case .error:
            return t.hasError
        case .waiting:
            return [.checkWait, .checking, .downloadWait, .seedWait].contains(t.status)
        }
    }
}

/// The single active sidebar filter applied to the torrent list.
enum SidebarFilter: Equatable, Sendable {
    case status(StatusFilter)
    case tracker(String)
    case folder(String)

    func matches(_ t: Torrent) -> Bool {
        switch self {
        case .status(let f): return f.matches(t)
        case .tracker(let host): return t.trackerHost == host
        case .folder(let dir):
            return t.normalizedDownloadDir == Torrent.normalizeDownloadDir(dir)
        }
    }

    /// The default "show everything" filter.
    static let all = SidebarFilter.status(.all)
}
