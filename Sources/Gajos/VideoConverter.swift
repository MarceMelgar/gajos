import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoFormat: CaseIterable {
    case mp4, mov, m4v, hevc, hd720, gif, audio, mp3, webm, mkv, avi

    static let gifMaxSeconds = 15.0

    var title: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .m4v: return "M4V"
        case .hevc: return "HEVC"
        case .hd720: return "720p"
        case .gif: return "GIF"
        case .audio: return "M4A"
        case .mp3: return "MP3"
        case .webm: return "WEBM"
        case .mkv: return "MKV"
        case .avi: return "AVI"
        }
    }

    var subtitle: String? {
        switch self {
        case .hevc, .hd720: return "mp4"
        case .audio, .mp3: return "audio"
        case .gif: return "hasta 15 s"
        default: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .hevc, .hd720: return "mp4"
        case .audio: return "m4a"
        case .mp3: return "mp3"
        default: return title.lowercased()
        }
    }

    var nameSuffix: String {
        switch self {
        case .hevc: return " HEVC"
        case .hd720: return " 720p"
        default: return ""
        }
    }

    /// Preset y contenedor de AVFoundation, que viene con macOS. nil si hace falta ffmpeg.
    var native: (preset: String, fileType: AVFileType)? {
        switch self {
        case .mp4: return (AVAssetExportPresetHighestQuality, .mp4)
        case .mov: return (AVAssetExportPresetHighestQuality, .mov)
        case .m4v: return (AVAssetExportPresetHighestQuality, .m4v)
        case .hevc: return (AVAssetExportPresetHEVCHighestQuality, .mp4)
        case .hd720: return (AVAssetExportPreset1280x720, .mp4)
        case .audio: return (AVAssetExportPresetAppleM4A, .m4a)
        case .gif, .mp3, .webm, .mkv, .avi: return nil
        }
    }

    var ffmpegArgs: [String] {
        let h264 = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        switch self {
        case .mp4, .mov, .m4v: return h264 + ["-movflags", "+faststart"]
        case .hevc: return ["-c:v", "libx265", "-crf", "24", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k"]
        case .hd720: return ["-vf", "scale=-2:720"] + h264
        case .gif: return ["-t", "\(Int(Self.gifMaxSeconds))", "-vf", "fps=10,scale=480:-2:flags=lanczos", "-loop", "0"]
        case .audio: return ["-vn", "-map", "0:a:0", "-c:a", "aac", "-b:a", "256k"]
        // La primera pista de audio entera, en MP3 de calidad alta (VBR ~190 kbps).
        case .mp3: return ["-vn", "-map", "0:a:0", "-c:a", "libmp3lame", "-q:a", "2"]
        case .webm: return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case .mkv: return ["-c", "copy"]
        case .avi: return ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        }
    }

    var isAvailable: Bool { native != nil || self == .gif || FFmpeg.path != nil }
}

enum VideoConverter {
    @discardableResult
    static func convert(_ url: URL, to format: VideoFormat) throws -> [URL] {
        let base = url.deletingPathExtension().lastPathComponent + format.nameSuffix
        let out = uniqueURL(url.deletingLastPathComponent()
            .appendingPathComponent(base).appendingPathExtension(format.fileExtension))

        let asset = AVURLAsset(url: url)
        let readable = asset.isReadable
        if readable, format == .audio || format == .mp3, asset.tracks(withMediaType: .audio).isEmpty {
            throw ConvertError.noAudio
        }
        if readable, format == .gif {
            try makeGIF(from: asset, to: out)
            return [out]
        }
        if readable, let native = format.native {
            try AVExport.run(asset, preset: native.preset, fileType: native.fileType, to: out)
            return [out]
        }

        guard FFmpeg.path != nil else {
            throw readable ? ConvertError.ffmpegUnavailable : ConvertError.unreadable(url.lastPathComponent)
        }
        try FFmpeg.convert(url, to: out, args: format.ffmpegArgs)
        return [out]
    }

    /// GIF de un tramo elegido del video (hasta 15 s), guardado junto al original.
    @discardableResult
    static func gif(_ url: URL, range: CMTimeRange) throws -> URL {
        let out = suffixed(url, "", ext: "gif")
        let asset = AVURLAsset(url: url)
        if asset.isReadable {
            try makeGIF(from: asset, to: out, range: range)
            return out
        }
        // MKV, WEBM…: con ffmpeg, mismo tamaño y velocidad de cuadros.
        guard let ffmpeg = FFmpeg.path else { throw ConvertError.unreadable(url.lastPathComponent) }
        let start = String(format: "%.3f", max(range.start.seconds, 0))
        let duration = String(format: "%.3f", min(range.duration.seconds, VideoFormat.gifMaxSeconds))
        let status = try Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-ss", start, "-t", duration,
                                            "-i", url.path, "-vf", "fps=10,scale=480:-2:flags=lanczos", "-loop", "0", out.path])
        if status != 0 {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.writeFailed(out.lastPathComponent)
        }
        return out
    }

    /// GIF de 10 cuadros por segundo, 480 px de ancho como máximo. Sin tramo: desde el principio.
    private static func makeGIF(from asset: AVURLAsset, to out: URL, range: CMTimeRange? = nil) throws {
        guard !asset.tracks(withMediaType: .video).isEmpty else { throw ConvertError.notAnImage(out.lastPathComponent) }
        let fps = 10.0
        let offset = range.map { max($0.start.seconds, 0) } ?? 0
        let available = asset.duration.seconds - offset
        let seconds = min(range?.duration.seconds ?? available, available, VideoFormat.gifMaxSeconds)
        let count = max(1, Int(seconds * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConvertError.writeFailed(out.lastPathComponent)
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]]

        var added = 0
        for i in 0..<count {
            let time = CMTime(seconds: offset + Double(i) / fps, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                CGImageDestinationAddImage(dest, image, frame as CFDictionary)
                added += 1
            }
        }
        guard added > 0, CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.writeFailed(out.lastPathComponent)
        }
    }
}
