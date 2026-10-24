import AppKit
import SwiftUI

/// Ventana de "Comprimir": elegir por calidad o por tamaño final, para uno o varios archivos.
struct CompressToolView: View {
    let files: [URL]
    let close: () -> Void

    private enum Mode: String { case quality = "Calidad", size = "Tamaño final" }
    private enum Unit: String, CaseIterable { case kb = "KB", mb = "MB" }

    @State private var mode: Mode = .quality
    @State private var quality = 0.6
    @State private var sizeText: String
    @State private var unit: Unit

    private let originalSize: Int64
    private let kind: MediaKind?
    private let isPDF: Bool

    init(files: [URL], close: @escaping () -> Void) {
        self.files = files
        self.close = close
        let first = files.first
        isPDF = first?.pathExtension.lowercased() == "pdf"
        kind = isPDF ? nil : first.flatMap(MediaKind.of)
        originalSize = first.map(fileSize) ?? 0
        // Sugerencia inicial: la mitad del tamaño actual.
        let half = Double(originalSize) / 2
        if half >= 1_000_000 {
            _unit = State(initialValue: .mb)
            _sizeText = State(initialValue: String(format: "%.1f", half / 1_000_000))
        } else {
            _unit = State(initialValue: .kb)
            _sizeText = State(initialValue: String(Int(max(half / 1000, 1))))
        }
    }

    private var targetBytes: Int64? {
        let normalized = sizeText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return Int64(value * (unit == .mb ? 1_000_000 : 1000))
    }

    private var sizeModeAvailable: Bool { kind != .video || Compressor.canTargetVideoSize }

    private var canCompress: Bool {
        mode == .quality || (sizeModeAvailable && targetBytes != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: files.first?.path ?? ""))
                    .resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) archivos")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(files.count == 1 ? "Pesa \(formatSize(originalSize))"
                                          : "El primero pesa \(formatSize(originalSize)); se aplica lo mismo a cada uno")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Picker("Comprimir por", selection: $mode) {
                Text(Mode.quality.rawValue).tag(Mode.quality)
                Text(Mode.size.rawValue).tag(Mode.size)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .quality {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Calidad")
                        Spacer()
                        Text("\(Int((quality * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $quality, in: 0.1...1)
                    HStack {
                        Text("Más liviano").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Mejor calidad").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if sizeModeAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(files.count == 1 ? "Que el archivo pese como máximo:" : "Que cada archivo pese como máximo:")
                    HStack {
                        TextField("Tamaño", text: $sizeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Picker("", selection: $unit) {
                            ForEach(Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        Spacer()
                    }
                    Text(sizeHint).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Para elegir el tamaño final de un video hace falta instalar los formatos extra (ffmpeg). Mientras tanto podés comprimir por calidad.")
                    .font(.callout).foregroundStyle(.orange)
            }

            if let note { Text(note).font(.caption).foregroundStyle(.orange) }

            HStack {
                Spacer()
                Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
                Button("Comprimir", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCompress)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var sizeHint: String {
        switch kind {
        case .audio, .video: return "Se calcula según la duración para quedar justo en ese tamaño."
        default: return "Se busca la mejor calidad que entra en ese tamaño."
        }
    }

    /// Avisos según el tipo de archivo y lo elegido.
    private var note: String? {
        if isPDF, mode == .size || quality < 0.9 {
            return "Para comprimir mucho un PDF, sus páginas se guardan como imágenes y el texto deja de poder seleccionarse. Con calidad 90 % o más el texto se mantiene."
        }
        if kind == .image, let ext = files.first?.pathExtension.lowercased(), ["png", "bmp", "gif", "tif", "tiff"].contains(ext) {
            return "En \(ext.uppercased()) no hay calidad para bajar: se achican las medidas de la imagen."
        }
        if kind == .video { return "El video se recodifica entero: si es largo, puede tardar." }
        return nil
    }

    private func start() {
        let target: CompressTarget
        switch mode {
        case .quality: target = .quality(quality)
        case .size:
            guard let bytes = targetBytes else { return }
            target = .size(bytes)
        }
        let files = files
        close()
        Toast.show(files.count == 1 ? "Comprimiendo…" : "Comprimiendo \(files.count) archivos…", ok: true, silent: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var messages: [String] = []
            var firstError: Error?
            for url in files {
                do { messages.append(try Compressor.compress(url, target: target)) }
                catch { firstError = firstError ?? error }
            }
            DispatchQueue.main.async {
                if messages.isEmpty, let firstError {
                    Toast.show(firstError.localizedDescription, ok: false)
                } else {
                    var text = messages.count <= 3 ? messages.joined(separator: "\n") : "\(messages.count) archivos comprimidos"
                    if let firstError { text += "\n(\(firstError.localizedDescription))" }
                    Toast.show(text, ok: true)
                }
            }
        }
    }
}
