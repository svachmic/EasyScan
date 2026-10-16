// Pure parsing helpers for the text `scanimage` prints. No I/O here, so everything is easy to test in isolation.
import Foundation

/// One line of `scanimage -L`: "device `xerox_mfp:libusb:000:017' is a Samsung M2070 Series multi-function peripheral".
struct SANEDeviceListing: Equatable {
    /// SANE device name, passed to `scanimage -d`.
    let name: String
    /// Everything after "is a": vendor, model and device type.
    let description: String
}

/// What `scanimage -d NAME --help` says about a device. Empty/nil fields mean "not reported".
struct SANEDeviceOptions: Equatable {
    /// Supported resolutions in dpi, ascending. For range-type resolutions this is a list of sensible steps.
    var resolutions: [Int] = []
    /// Set when the backend accepts any resolution in a range (then values outside `resolutions` are fine too).
    var resolutionRange: ClosedRange<Int>? = nil
    /// Scan mode names exactly as the backend spells them ("Color", "Gray", "Lineart", "24bit Color", …).
    var modes: [String] = []
    /// Document sources ("Flatbed", "ADF", …) and whether the option is currently active.
    var sources: [String] = []
    var sourceActive = false
    /// Geometry maxima in millimetres (only filled in when the backend uses mm).
    var maxLeft: Double? = nil
    var maxTop: Double? = nil
    var maxWidth: Double? = nil
    var maxHeight: Double? = nil
    /// True when the "Options specific to device" section was present, i.e. the device was actually opened.
    var foundDeviceSection = false

    var hasGeometry: Bool { maxWidth != nil && maxHeight != nil }
}

enum SANEParsing {
    // MARK: - Device list (`scanimage -L`)

    static func parseDeviceList(_ text: String) -> [SANEDeviceListing] {
        var result: [SANEDeviceListing] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            guard let open = line.range(of: "device `"),
                  let close = line.range(of: "' is a ", range: open.upperBound..<line.endIndex) else { continue }
            let name = String(line[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            let description = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !result.contains(where: { $0.name == name }) else { continue }
            result.append(SANEDeviceListing(name: name, description: description))
        }
        return result
    }

    /// Device types scanimage appends after vendor and model; they are noise in a scanner picker.
    private static let typeSuffixes = [
        "multi-function peripheral", "multifunction peripheral", "flatbed scanner", "sheetfed scanner",
        "handheld scanner", "film scanner", "slide scanner", "adf scanner", "virtual device", "still camera",
        "video camera", "webcam", "scanner",
    ]

    /// "Samsung M2070 Series multi-function peripheral" -> "Samsung M2070 Series".
    static func cleanDescription(_ description: String) -> String {
        var text = description.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var changed = true
        while changed {
            changed = false
            for suffix in typeSuffixes where text.lowercased().hasSuffix(" " + suffix) {
                text = String(text.dropLast(suffix.count + 1)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        // Some backends repeat the vendor in the model ("Samsung Samsung M2070").
        let words = text.split(separator: " ")
        if words.count >= 2, words[0].lowercased() == words[1].lowercased() {
            text = words.dropFirst().joined(separator: " ")
        }
        return text.isEmpty ? description.trimmingCharacters(in: .whitespaces) : text
    }

    static func transport(forDeviceName name: String) -> String {
        name.lowercased().contains("usb") ? "USB" : "Network"
    }

    // MARK: - Device options (`scanimage -d NAME --help`)

    static func parseHelp(_ text: String) -> SANEDeviceOptions {
        var options = SANEDeviceOptions()
        var lines = text.components(separatedBy: .newlines)
        if let start = lines.firstIndex(where: { $0.contains("Options specific to device") }) {
            options.foundDeviceSection = true
            lines = Array(lines[(start + 1)...])
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let (option, rest) = splitOption(line) else { continue }
            let (spec, defaultValue) = splitDefault(rest)
            switch option {
            case "--resolution":
                let value = parseNumericSpec(spec)
                if let range = value.range {
                    let low = Int(range.lowerBound.rounded(.up)), high = Int(range.upperBound.rounded(.down))
                    if low > 0, high >= low {
                        options.resolutionRange = low...high
                        options.resolutions = sensibleResolutions(in: low...high, step: value.step.map { Int($0) })
                    }
                } else {
                    options.resolutions = Array(Set(value.list.map { Int($0.rounded()) }.filter { $0 > 0 })).sorted()
                }
            case "--mode":
                options.modes = splitList(spec)
            case "--source":
                options.sources = splitList(spec)
                options.sourceActive = defaultValue?.lowercased() != "inactive"
            case "-l", "-t", "-x", "-y":
                let value = parseNumericSpec(spec)
                guard value.unit == "mm", let maximum = value.range?.upperBound, maximum > 0 else { continue }
                switch option {
                case "-l": options.maxLeft = maximum
                case "-t": options.maxTop = maximum
                case "-x": options.maxWidth = maximum
                default: options.maxHeight = maximum
                }
            default:
                break
            }
        }
        return options
    }

    /// Standard scanner resolutions inside `range` (respecting `step` when the backend quantizes), so a
    /// "50..1200dpi" backend gets a picker of 50, 75, 100, 150, … instead of 1151 entries.
    static func sensibleResolutions(in range: ClosedRange<Int>, step: Int?) -> [Int] {
        let standard = [50, 75, 100, 150, 200, 300, 400, 600, 800, 1200, 2400, 4800, 9600]
        var values = standard.filter { value in
            guard range.contains(value) else { return false }
            guard let step, step > 1 else { return true }
            return (value - range.lowerBound) % step == 0
        }
        if values.isEmpty { values = range.lowerBound == range.upperBound ? [range.lowerBound] : [range.lowerBound, range.upperBound] }
        return values
    }

    /// Maps a backend mode name onto EasyScan's three modes. Halftone/dither modes are not offered (nil).
    static func colorMode(forSANEMode name: String) -> ScanColorMode? {
        let lower = name.lowercased()
        if lower.contains("halftone") || lower.contains("dither") { return nil }
        if lower.contains("lineart") || lower.contains("line art") || lower.contains("binary")
            || lower.contains("black") || lower == "bw" || lower.contains("monochrome") { return .blackWhite }
        if lower.contains("gray") || lower.contains("grey") { return .gray }
        if lower.contains("color") || lower.contains("colour") || lower.contains("rgb") { return .color }
        return nil
    }

    /// For each EasyScan mode, the backend name to pass to `--mode`. Prefers the SANE standard spellings.
    static func modeNames(from names: [String]) -> [ScanColorMode: String] {
        let standard: [ScanColorMode: String] = [.color: "Color", .gray: "Gray", .blackWhite: "Lineart"]
        var result: [ScanColorMode: String] = [:]
        for mode in ScanColorMode.allCases {
            if let exact = names.first(where: { $0.caseInsensitiveCompare(standard[mode] ?? "") == .orderedSame }) {
                result[mode] = exact
            } else if let match = names.first(where: { colorMode(forSANEMode: $0) == mode }) {
                result[mode] = match
            }
        }
        return result
    }

    // MARK: - Progress (`scanimage --progress`)

    /// "Progress: 12.3%" -> 0.123.
    static func progressFraction(fromLine line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Progress:") else { return nil }
        let number = trimmed.dropFirst("Progress:".count).replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Double(number), percent.isFinite else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    // MARK: - Errors

    /// stderr lines worth showing to a person: no progress output, no blank lines.
    static func meaningfulLines(of stderr: String) -> [String] {
        stderr.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Progress:") }
    }

    /// True when scanimage could not open the device at all (unplugged, powered off, or its USB address changed).
    static func indicatesUnreachableDevice(_ stderr: String) -> Bool {
        meaningfulLines(of: stderr).contains { line in
            let lower = line.lowercased()
            return lower.contains("open of device") && (lower.contains("invalid argument") || lower.contains("no such device")
                || lower.contains("not found") || lower.contains("error during device i/o"))
        }
    }

    /// Turns a failed run into a message a person can act on. Keeps the raw stderr tail when it is short.
    static func friendlyError(stderr: String, exitCode: Int32, scannerName: String? = nil) -> ScanError {
        let lines = meaningfulLines(of: stderr)
        let all = lines.joined(separator: "\n").lowercased()
        let tail = lines.suffix(2).joined(separator: " ")
        let scanner = scannerName.map { "“\($0)”" } ?? "The scanner"

        if all.contains("operation was cancelled") { return .cancelled } // e.g. the Stop button on the device

        let friendly: String
        if all.contains("device busy") {
            friendly = "The scanner is in use by another application. Close other scanning apps or wait for them to finish, then try again."
        } else if all.contains("no sane devices") {
            friendly = "No scanner found. Make sure the scanner is turned on and connected."
        } else if indicatesUnreachableDevice(stderr) {
            friendly = "\(scanner) could not be opened. Make sure it is turned on and connected, then try again."
        } else if all.contains("invalid argument") || all.contains("unrecognized option") || all.contains("invalid option") {
            let offending = lines.reversed().lazy.compactMap { offendingOption(in: $0) }.first
            friendly = offending.map { "The scanner rejected the setting \($0)." }
                ?? "The scanner rejected one of the scan settings."
        } else if all.contains("feeder jammed") || all.contains("jammed") {
            friendly = "The document feeder is jammed."
        } else if all.contains("out of documents") || all.contains("no documents") {
            friendly = "The document feeder is empty."
        } else if all.contains("cover is open") || all.contains("cover open") {
            friendly = "The scanner cover is open."
        } else if all.contains("access to resource has been denied") || all.contains("permission denied") {
            friendly = "Permission to use the scanner was denied."
        } else if all.contains("out of memory") {
            friendly = "The scanner ran out of memory. Try a lower resolution or a smaller area."
        } else if all.contains("lamp") {
            friendly = "The scanner lamp failed."
        } else if all.contains("error during device i/o") {
            friendly = "Communication with the scanner failed. Check the cable and that the scanner is on, then try again."
        } else if all.contains("operation not supported") {
            friendly = "The scanner does not support this operation."
        } else {
            friendly = exitCode != 0 ? "Scanning failed (scanimage exit code \(exitCode))." : "Scanning failed."
        }
        let message = (!tail.isEmpty && tail.count <= 200) ? "\(friendly) (\(tail))" : friendly
        return ScanError(message, code: Int(exitCode))
    }

    // MARK: - Formatting

    /// A millimetre value for -l/-t/-x/-y: rounded down to 0.001 mm (never past a backend maximum), no trailing zeros.
    static func formatMillimeters(_ value: Double) -> String {
        // The epsilon keeps binary noise (216.069 - 200 = 16.06899…) from losing a whole 0.001 mm.
        let truncated = (max(value, 0) * 1000 + 1e-6).rounded(.down) / 1000
        if truncated == truncated.rounded() { return String(Int(truncated)) }
        var text = String(format: "%.3f", truncated)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Private helpers

    /// "--resolution 75|150dpi [150]" -> ("--resolution", "75|150dpi [150]"). Only the options we care about.
    private static func splitOption(_ line: String) -> (String, String)? {
        for option in ["--resolution", "--mode", "--source", "-l", "-t", "-x", "-y"] where line.hasPrefix(option + " ") {
            return (option, String(line.dropFirst(option.count + 1)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// "Lineart|Gray|24bit Color [Color]" -> ("Lineart|Gray|24bit Color", "Color"). Mode names may contain spaces,
    /// so the default is taken from the LAST " [".
    private static func splitDefault(_ rest: String) -> (spec: String, defaultValue: String?) {
        guard rest.hasSuffix("]"), let bracket = rest.range(of: " [", options: .backwards) else {
            return (rest, nil)
        }
        let spec = String(rest[..<bracket.lowerBound]).trimmingCharacters(in: .whitespaces)
        let value = String(rest[bracket.upperBound...].dropLast())
        return (spec, value)
    }

    private static func splitList(_ spec: String) -> [String] {
        spec.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Parses "0..216.069mm (in steps of 1)" or "75|100|150dpi".
    private static func parseNumericSpec(_ spec: String) -> (list: [Double], range: ClosedRange<Double>?, step: Double?, unit: String) {
        var body = spec
        var step: Double?
        if let open = body.range(of: "(") {
            let note = body[open.upperBound...]
            if let stepRange = note.range(of: "in steps of ") {
                let digits = note[stepRange.upperBound...].prefix { $0.isNumber || $0 == "." }
                step = Double(digits)
            }
            body = String(body[..<open.lowerBound])
        }
        body = body.trimmingCharacters(in: .whitespaces)
        // Unit = trailing characters that cannot be part of a number list ("dpi", "mm", "pel", "%").
        let numberCharacters = Set("0123456789.|-+")
        let unit = String(body.reversed().prefix { !numberCharacters.contains($0) }.reversed())
        body = String(body.dropLast(unit.count))

        if body.contains("..") {
            let parts = body.components(separatedBy: "..")
            if parts.count == 2, let low = Double(parts[0]), let high = Double(parts[1]), low <= high {
                return ([], low...high, step, unit)
            }
            return ([], nil, step, unit)
        }
        let list = body.components(separatedBy: "|").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return (list, nil, step, unit)
    }

    /// Finds the option a "setting of option --mode failed (Invalid argument)" style message is about.
    private static func offendingOption(in line: String) -> String? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "`" || $0 == "(" || $0 == ")" || $0 == ":" })
        if let long = words.first(where: { $0.hasPrefix("--") && $0.count > 2 }) { return String(long) }
        if let short = words.first(where: { ["-l", "-t", "-x", "-y", "-d"].contains(String($0)) }) { return String(short) }
        return nil
    }
}
