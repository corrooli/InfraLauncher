// Open shell entries in the terminal app of choice.

import AppKit

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal, iterm, ghostty, kitty, wezterm, alacritty

    static let prefsKey = "terminalApp"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        case .ghostty: "Ghostty"
        case .kitty: "kitty"
        case .wezterm: "WezTerm"
        case .alacritty: "Alacritty"
        }
    }

    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .kitty: "net.kovidgoyal.kitty"
        case .wezterm: "com.github.wez.wezterm"
        case .alacritty: "org.alacritty"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }

    var icon: NSImage? {
        appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private static let scriptQueue = DispatchQueue(label: "InfraLauncher.applescript")

    static var installed: [TerminalApp] { allCases.filter(\.isInstalled) }

    /// Chosen app; falls back to Terminal if it isn't installed (anymore).
    static var current: TerminalApp {
        let chosen = UserDefaults.standard.string(forKey: prefsKey).flatMap(TerminalApp.init(rawValue:)) ?? .terminal
        return chosen.isInstalled ? chosen : .terminal
    }

    /// Runs an executable script in a new window of the app.
    func run(script: URL, completion: @escaping (Error?) -> Void) {
        guard let app = appURL else {
            completion(CocoaError(.fileNoSuchFile))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let done: (NSRunningApplication?, Error?) -> Void = { _, err in
            DispatchQueue.main.async { completion(err) }
        }
        switch self {
        case .terminal:
            // Terminal runs an opened .command script directly.
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: config, completionHandler: done)
        case .iterm:
            // iTerm2 asks before running opened scripts; via AppleScript it runs without asking
            // in a new window, and the shell stays open afterwards like in Terminal.
            // The path is in the temporary folder and contains no quotes.
            let path = script.path
            let source = """
            tell application id "\(bundleID)"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "'\(path)'"
            end tell
            """
            Self.scriptQueue.async {
                var info: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&info)
                let err = info.map { _ in CocoaError(.featureUnsupported) }
                DispatchQueue.main.async { completion(err) }
            }
        case .ghostty, .alacritty:
            config.createsNewApplicationInstance = true
            config.arguments = ["-e", script.path]
            NSWorkspace.shared.openApplication(at: app, configuration: config, completionHandler: done)
        case .kitty:
            config.createsNewApplicationInstance = true
            config.arguments = [script.path]
            NSWorkspace.shared.openApplication(at: app, configuration: config, completionHandler: done)
        case .wezterm:
            config.createsNewApplicationInstance = true
            config.arguments = ["start", "--", script.path]
            NSWorkspace.shared.openApplication(at: app, configuration: config, completionHandler: done)
        }
    }
}
