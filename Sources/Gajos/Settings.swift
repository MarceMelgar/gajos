import AppKit
import Combine

enum Modifier: String, CaseIterable, Identifiable {
    case shift, control, option, command

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }

    var label: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        }
    }
}

enum WheelStyle: String, CaseIterable {
    case glass, solid
}

struct TerminalApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    static let known = [
        TerminalApp(bundleID: "com.apple.Terminal", name: "Terminal"),
        TerminalApp(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        TerminalApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        TerminalApp(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        TerminalApp(bundleID: "com.github.wez.wezterm", name: "WezTerm"),
    ]

    static var installed: [TerminalApp] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    static let maxFolders = 3

    private let defaults = UserDefaults.standard

    @Published var conversionModifier: Modifier {
        didSet { defaults.set(conversionModifier.rawValue, forKey: "conversionModifier") }
    }
    @Published var toolsModifier: Modifier {
        didSet { defaults.set(toolsModifier.rawValue, forKey: "toolsModifier") }
    }
    @Published var actionsModifier: Modifier {
        didSet { defaults.set(actionsModifier.rawValue, forKey: "actionsModifier") }
    }
    @Published var style: WheelStyle {
        didSet { defaults.set(style.rawValue, forKey: "style") }
    }
    @Published var sound: Bool {
        didSet { defaults.set(sound, forKey: "sound") }
    }
    @Published var quality: Double {
        didSet { defaults.set(quality, forKey: "quality") }
    }
    @Published var terminalBundleID: String {
        didSet { defaults.set(terminalBundleID, forKey: "terminalBundleID") }
    }
    @Published var favoriteFolders: [String] {
        didSet { defaults.set(favoriteFolders, forKey: "favoriteFolders") }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    private init() {
        conversionModifier = Modifier(rawValue: defaults.string(forKey: "conversionModifier") ?? "") ?? .shift
        toolsModifier = Modifier(rawValue: defaults.string(forKey: "toolsModifier") ?? "") ?? .command
        actionsModifier = Modifier(rawValue: defaults.string(forKey: "actionsModifier") ?? "") ?? .control
        style = WheelStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .glass
        sound = defaults.object(forKey: "sound") as? Bool ?? true
        quality = defaults.object(forKey: "quality") as? Double ?? 0.85
        terminalBundleID = defaults.string(forKey: "terminalBundleID") ?? "com.apple.Terminal"
        favoriteFolders = defaults.stringArray(forKey: "favoriteFolders") ?? []
    }
}
