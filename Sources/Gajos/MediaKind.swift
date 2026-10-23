import Foundation
import UniformTypeIdentifiers

/// Qué tipo de archivo se está arrastrando, para mostrar las conversiones que correspondan.
enum MediaKind {
    case image, audio, video

    // Extensiones que macOS no siempre clasifica bien por su cuenta.
    private static let videoExtensions: Set = ["mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m2ts", "3gp"]
    private static let audioExtensions: Set = ["opus", "ogg", "oga", "flac", "wma", "ape", "m4p", "aac", "amr", "caf"]

    static func of(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) || type.conforms(to: .pdf) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }
}

/// ffmpeg es opcional: si está instalado, se habilitan MP3, OGG, OPUS, WEBM, MKV y AVI.
enum FFmpeg {
    static var path: String? {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "\(home)/.local/bin/ffmpeg", "\(home)/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func convert(_ input: URL, to output: URL, args: [String]) throws {
        guard let path else { throw ConvertError.ffmpegUnavailable }
        let status = try Shell.run(path, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", input.path] + args + [output.path])
        if status != 0 {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError.writeFailed(output.lastPathComponent)
        }
    }
}
