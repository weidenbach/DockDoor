import AppKit
import Defaults
import SwiftUI

/// Coordinates multiple preview windows, one for each monitor containing windows
final class MultiMonitorPreviewCoordinator {
    private var previewPanelsByScreen: [String: NSPanel] = [:]
    /// Per-screen coordinators keyed by screen identifier.
    private var _coordinatorsByScreen: [String: PreviewStateCoordinator] = [:]
    /// Per-screen window lists (in the same order as the per-screen coordinator's windows).
    private var windowsByScreen: [String: [WindowInfo]] = [:]
    /// Full global window list; used for global-index lookups.
    private var allWindows: [WindowInfo] = []
    /// Maps screen identifier to its stable monitor slot (0 = main, 1 = second …).
    private var monitorSlotByScreenId: [String: Int] = [:]

    // MARK: - Window grouping

    func groupWindowsByScreen(_ windows: [WindowInfo]) -> [String: [WindowInfo]] {
        // Snapshot screens once to avoid repeated OS calls per window.
        let screens = NSScreen.screens
        let primary = screens.first
        var grouped: [String: [WindowInfo]] = [:]
        for window in windows {
            let screenId: String
            if let identifier = window.screenIdentifier {
                screenId = identifier
            } else {
                // Convert from CG coordinates (origin top-left) to NS coordinates (origin bottom-left).
                let cgOrigin = window.frame.origin
                let nsOrigin = primary.map { CGPoint(x: cgOrigin.x, y: $0.frame.maxY - cgOrigin.y) } ?? cgOrigin
                let screen = screens.first { NSPointInRect(nsOrigin, $0.frame) } ?? NSScreen.main!
                screenId = screen.uniqueIdentifier()
            }
            grouped[screenId, default: []].append(window)
        }
        return grouped
    }

    func screenForIdentifier(_ identifier: String) -> NSScreen? {
        NSScreen.screens.first { $0.uniqueIdentifier() == identifier }
    }

    // MARK: - Panel / coordinator management

    func createPreviewPanel(for screenId: String) -> NSPanel {
        if let existing = previewPanelsByScreen[screenId] { return existing }
        let styleMask: NSWindow.StyleMask = [.nonactivatingPanel, .fullSizeContentView, .borderless]
        let panel = NSPanel(contentRect: .zero, styleMask: styleMask, backing: .buffered, defer: false)
        panel.level = Defaults[.raisedWindowLevel] ? .statusBar : .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        previewPanelsByScreen[screenId] = panel
        return panel
    }

    func registerCoordinator(_ coordinator: PreviewStateCoordinator, windows: [WindowInfo], for screenId: String, monitorSlot: Int = 0) {
        _coordinatorsByScreen[screenId] = coordinator
        windowsByScreen[screenId] = windows
        monitorSlotByScreenId[screenId] = monitorSlot
    }

    /// Store the full ordered window list so per-monitor windows can be mapped to global indices.
    func setGlobalWindows(_ windows: [WindowInfo]) {
        allWindows = windows
    }

    // MARK: - Stable screen ordering

    /// Builds a slot mapping for all currently connected screens.
    /// Slot 0 is always assigned to the geometrically center screen (by midX).
    /// Left-of-center screens get slots 1, 2… (closest to center first).
    /// Right-of-center screens continue numbering after that.
    /// This means the same physical monitor always keeps slot 0 regardless of which
    /// screens have windows open, and regardless of where the macOS menu bar is.
    static func buildGlobalSlotMapping() -> [String: Int] {
        let all = NSScreen.screens
        guard !all.isEmpty else { return [:] }
        let sorted = all.sorted { $0.frame.midX < $1.frame.midX }
        let centerIdx = sorted.count / 2
        // Order: center, then left-of-center right-to-left (nearest first), then right-of-center left-to-right
        var ordered: [NSScreen] = [sorted[centerIdx]]
        ordered += sorted[..<centerIdx].reversed()
        ordered += sorted[(centerIdx + 1)...]
        var mapping: [String: Int] = [:]
        for (slot, screen) in ordered.enumerated() {
            mapping[screen.uniqueIdentifier()] = slot
        }
        return mapping
    }

    /// Sorts a set of active screen IDs by their global slot number (center = slot 0).
    static func stableScreenOrder(activeScreenIds: Set<String>) -> [String] {
        let slotMapping = buildGlobalSlotMapping()
        return activeScreenIds.sorted { a, b in
            let sa = slotMapping[a] ?? Int.max
            let sb = slotMapping[b] ?? Int.max
            return sa < sb
        }
    }

    // MARK: - Global index lookup

    /// Returns the global window index for the window at `localIndex` on monitor `slot`.
    func globalIndex(forMonitorSlot slot: Int, localIndex: Int) -> Int? {
        guard let screenId = monitorSlotByScreenId.first(where: { $0.value == slot })?.key,
              let windows = windowsByScreen[screenId],
              localIndex < windows.count
        else { return nil }
        let target = windows[localIndex]
        return allWindows.firstIndex { $0.id == target.id }
    }

    // MARK: - Tab cycling sync

    // Given the globally selected WindowInfo from the main coordinator, find which
    // per-screen coordinator owns it and update its currIndex; clear all others.
    func syncSelection(selectedWindow: WindowInfo?) {
        for (screenId, coordinator) in _coordinatorsByScreen {
            guard let windows = windowsByScreen[screenId] else { continue }
            if let selected = selectedWindow,
               let idx = windows.firstIndex(where: { $0.id == selected.id })
            {
                coordinator.currIndex = idx
            } else {
                coordinator.currIndex = -1
            }
        }
    }

    // MARK: - Window removal

    /// Removes a window by ID from allWindows, the per-screen window list, and the per-screen coordinator.
    @MainActor func removeWindow(withId windowId: CGWindowID) {
        allWindows.removeAll { $0.id == windowId }
        for screenId in windowsByScreen.keys {
            guard let idx = windowsByScreen[screenId]?.firstIndex(where: { $0.id == windowId }) else { continue }
            windowsByScreen[screenId]?.remove(at: idx)
            _coordinatorsByScreen[screenId]?.removeWindow(at: idx)
            // If the screen has no more windows, tear down its panel.
            if windowsByScreen[screenId]?.isEmpty == true {
                previewPanelsByScreen[screenId]?.orderOut(nil)
                previewPanelsByScreen.removeValue(forKey: screenId)
                _coordinatorsByScreen.removeValue(forKey: screenId)
                windowsByScreen.removeValue(forKey: screenId)
                monitorSlotByScreenId.removeValue(forKey: screenId)
            }
            break
        }
    }

    // MARK: - Cleanup

    func hideAllWindows() {
        for window in previewPanelsByScreen.values {
            window.orderOut(nil)
        }
        previewPanelsByScreen.removeAll()
        _coordinatorsByScreen.removeAll()
        windowsByScreen.removeAll()
        allWindows.removeAll()
        monitorSlotByScreenId.removeAll()
    }

    /// True if any per-screen panel is currently on screen.
    /// Uses `contains` to avoid an Array allocation on every check.
    var hasVisibleWindows: Bool {
        previewPanelsByScreen.values.contains { $0.isVisible }
    }

    func getAllWindows() -> [NSPanel] { Array(previewPanelsByScreen.values) }
    func panelForScreen(_ screenId: String) -> NSPanel? { previewPanelsByScreen[screenId] }
    func removePanelForScreen(_ screenId: String) { previewPanelsByScreen.removeValue(forKey: screenId) }

    /// Exposed for accessing per-screen coordinators (e.g., to sync selection back to main).
    var coordinatorsByScreen: [String: PreviewStateCoordinator] {
        _coordinatorsByScreen
    }
}
