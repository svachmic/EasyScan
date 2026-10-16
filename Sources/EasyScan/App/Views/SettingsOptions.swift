// The choices the settings pickers offer for the selected scanner, and how to fall back to a valid one.
import Foundation

struct SettingsOptions: Equatable {
    static let fallbackResolutions = [75, 100, 150, 200, 300, 600]

    let modes: [ScanColorMode]
    let resolutions: [Int]

    init(capabilities: ScannerCapabilities?) {
        let modes = capabilities?.modes ?? []
        let resolutions = capabilities?.resolutions ?? []
        self.modes = modes.isEmpty ? ScanColorMode.allCases : modes
        self.resolutions = resolutions.isEmpty ? SettingsOptions.fallbackResolutions : resolutions
    }

    /// `mode` if offered, otherwise the first offered mode.
    func validMode(_ mode: ScanColorMode) -> ScanColorMode {
        modes.contains(mode) ? mode : (modes.first ?? mode)
    }

    /// `resolution` if offered, otherwise the closest offered resolution.
    func validResolution(_ resolution: Int) -> Int {
        if resolutions.contains(resolution) { return resolution }
        return resolutions.min { abs($0 - resolution) < abs($1 - resolution) } ?? resolution
    }
}
