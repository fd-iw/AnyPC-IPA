import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Browse the PC's files, download them to the iPhone and upload files or photos.
struct FileBrowserView: View {
    @ObservedObject var conn: PCConnection
    @Environment(\.dismiss) private var dismiss

    @State private var listing: FsListing?
    @State private var loading = false
    @State private var errorText: String?
    @State private var transfer: Transfer?
    @State private var share: ShareItem?
    @State private var showDocumentPicker = false
    @State private var showPhotoPicker = false

    struct Transfer {
        var id: UInt32?
        var name: String
        var progress: Double
        var upload: Bool
    }

    private var title: String {
        guard let path = listing?.path, !path.isEmpty else { return "This PC" }
        let trimmed = path.hasSuffix("\\") || path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        return parts.last.map(String.init) ?? path
    }

    var body: some View {
        NavigationView {
            List {
                if let listing = listing, !listing.path.isEmpty {
                    Button {
                        load(listing.parent)
                    } label: {
                        Label(listing.parent.isEmpty ? "All drives" : "Up one level", systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(listing?.entries ?? []) { e in
                    Button {
                        if e.isDir { load(e.path) } else { download(e) }
                    } label: {
                        FileRow(entry: e, isRoot: listing?.path.isEmpty ?? true)
                    }
                    .disabled(transfer != nil && !e.isDir)
                }
            }
            .listStyle(.plain)
            .overlay(overlay)
            .refreshable { load(listing?.path ?? "") }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Photos & Videos", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showDocumentPicker = true
                        } label: {
                            Label("From Files", systemImage: "doc")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(transfer != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let t = transfer {
                    TransferBar(transfer: t) {
                        if let id = t.id { conn.cancelTransfer(id) }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            conn.stopStream() // give file transfers the bandwidth
            if listing == nil { load("") }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { urls in urls.forEach(upload) }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { url in upload(url) }
        }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if loading && listing == nil {
            ProgressView()
        } else if let errorText = errorText {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                Text(errorText).multilineTextAlignment(.center).foregroundColor(.secondary)
                Button("Retry") { load(listing?.path ?? "") }
            }
            .padding()
            .background(Color(.systemBackground))
        } else if listing?.entries.isEmpty == true {
            Text("This folder is empty").foregroundColor(.secondary)
        }
    }

    private func load(_ path: String) {
        loading = true
        errorText = nil
        conn.list(path) { result in
            loading = false
            switch result {
            case .success(let l): listing = l
            case .failure(let e): errorText = e.localizedDescription
            }
        }
    }

    private func download(_ e: FsEntry) {
        transfer = Transfer(id: nil, name: e.name, progress: 0, upload: false)
        let id = conn.download(e.path, progress: { p in
            transfer?.progress = p
        }, done: { result in
            transfer = nil
            switch result {
            case .success(let url): share = ShareItem(url: url)
            case .failure(let err): conn.showToast(err.localizedDescription)
            }
        })
        transfer?.id = id
    }

    private func upload(_ url: URL) {
        let folder = listing?.path ?? ""
        transfer = Transfer(id: nil, name: url.lastPathComponent, progress: 0, upload: true)
        conn.upload(url, toFolder: folder, progress: { p in
            transfer?.progress = p
        }, done: { result in
            transfer = nil
            switch result {
            case .success(let name):
                conn.showToast("Sent \(name)")
                load(folder)
            case .failure(let err):
                conn.showToast(err.localizedDescription)
            }
        })
    }
}

private struct FileRow: View {
    let entry: FsEntry
    let isRoot: Bool

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private var icon: String {
        if isRoot { return "internaldrive" }
        if entry.isDir { return "folder.fill" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "bmp", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv", "wmv": return "film"
        case "mp3", "wav", "flac", "m4a", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z": return "archivebox"
        case "exe", "msi": return "gearshape"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(entry.isDir || isRoot ? .accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundColor(.primary).lineLimit(1)
                if !entry.isDir {
                    Text(Self.sizeFormatter.string(fromByteCount: entry.size))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if entry.isDir {
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            } else {
                Image(systemName: "arrow.down.circle").foregroundColor(.accentColor)
            }
        }
    }
}

private struct TransferBar: View {
    let transfer: FileBrowserView.Transfer
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: transfer.upload ? "arrow.up.circle" : "arrow.down.circle")
                Text("\(transfer.upload ? "Sending" : "Downloading") \(transfer.name)")
                    .font(.footnote).lineLimit(1)
                Spacer()
                if !transfer.upload {
                    Button("Cancel", action: onCancel).font(.footnote)
                }
            }
            ProgressView(value: min(max(transfer.progress, 0), 1))
        }
        .padding(12)
        .background(.regularMaterial)
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

/// Photo/video picker. Uses the "compatible" representation so HEIC/HEVC arrive as JPEG/H.264,
/// which Windows opens without extra codecs.
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider else { return }
            let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true }
                ?? provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
                ?? UTType.item.identifier
            let suggested = provider.suggestedName ?? "Photo"
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url = url else { return }
                // The provided file is deleted when this block returns, so copy it first.
                let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "dat") : url.pathExtension
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(suggested).\(ext)")
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    DispatchQueue.main.async { self.parent.onPick(dest) }
                } catch {}
            }
        }
    }
}
