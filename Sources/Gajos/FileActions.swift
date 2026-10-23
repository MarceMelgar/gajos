import AppKit

enum FileActionError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

enum FileActions {
    static func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func openTerminal(at urls: [URL]) throws {
        guard let first = urls.first else { return }
        let folder = first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        let bundleID = Settings.shared.terminalBundleID
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw FileActionError.failed("No se encontró la app de terminal")
        }
        try Shell.run("/usr/bin/open", ["-a", app.path, folder.path])
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @discardableResult
    static func duplicate(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let base = url.deletingPathExtension().lastPathComponent + " copia"
            var target = url.deletingLastPathComponent().appendingPathComponent(base)
            if !url.pathExtension.isEmpty { target.appendPathExtension(url.pathExtension) }
            target = uniqueURL(target)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        }
    }

    @discardableResult
    static func zip(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw FileActionError.failed("No hay archivos") }
        let folder = first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archivo"
        let out = uniqueURL(folder.appendingPathComponent(name).appendingPathExtension("zip"))

        let status: Int32
        if urls.count == 1 {
            status = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
        } else {
            // Rutas relativas a la carpeta del primero, para que el ZIP no guarde la ruta completa.
            let names = urls.map { $0.deletingLastPathComponent() == folder ? $0.lastPathComponent : $0.path }
            status = try Shell.run("/usr/bin/zip", ["-r", "-q", "-y", out.path] + names, in: folder)
        }
        if status != 0 { throw FileActionError.failed("No se pudo crear el ZIP") }
        return out
    }

    static func copy(_ urls: [URL], to folder: URL) throws {
        for url in urls {
            let target = uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.copyItem(at: url, to: target)
        }
    }

    static func move(_ urls: [URL], to folder: URL) throws {
        for url in urls {
            let target = uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.moveItem(at: url, to: target)
        }
    }

    static func pickFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String], in directory: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Si el archivo ya existe, agrega " 2", " 3"… antes de la extensión.
func uniqueURL(_ url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return url }
    let folder = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    var n = 2
    while true {
        var candidate = folder.appendingPathComponent("\(base) \(n)")
        if !ext.isEmpty { candidate.appendPathExtension(ext) }
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        n += 1
    }
}
