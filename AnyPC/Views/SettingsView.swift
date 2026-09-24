import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.qualityKey) private var quality = 60.0
    @AppStorage(Prefs.fpsKey) private var fps = 20.0
    @AppStorage(Prefs.maxWidthKey) private var maxWidth = 1136
    @AppStorage(Prefs.sensitivityKey) private var sensitivity = 1.3
    @AppStorage(Prefs.modeKey) private var mode = ControlMode.trackpad.rawValue
    @ObservedObject private var store = PCStore.shared
    @State private var confirmForget = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Screen"), footer: Text("Lower quality and resolution make the picture smoother on slow Wi-Fi.")) {
                    VStack(alignment: .leading) {
                        Text("Quality: \(Int(quality))")
                        Slider(value: $quality, in: 30...90, step: 5)
                    }
                    VStack(alignment: .leading) {
                        Text("Frame rate: \(Int(fps)) fps")
                        Slider(value: $fps, in: 5...30, step: 5)
                    }
                    Picker("Resolution", selection: $maxWidth) {
                        Text("Low (800 px)").tag(800)
                        Text("iPhone (1136 px)").tag(1136)
                        Text("High (1600 px)").tag(1600)
                        Text("Full HD (1920 px)").tag(1920)
                    }
                }

                Section(header: Text("Control")) {
                    Picker("Mode", selection: $mode) {
                        Text("Trackpad").tag(ControlMode.trackpad.rawValue)
                        Text("Touch").tag(ControlMode.touch.rawValue)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        Text("Pointer speed: \(sensitivity, specifier: "%.1f")×")
                        Slider(value: $sensitivity, in: 0.5...3, step: 0.1)
                    }
                }

                Section(header: Text("Paired PCs")) {
                    if store.pcs.isEmpty {
                        Text("None").foregroundColor(.secondary)
                    }
                    ForEach(store.pcs) { pc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pc.name)
                            Text("\(pc.host) • code \(String(pc.fingerprint.prefix(8)).uppercased())")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onDelete { offsets in offsets.map { store.pcs[$0].id }.forEach(store.remove) }
                    if !store.pcs.isEmpty {
                        Button("Forget all PCs", role: .destructive) { confirmForget = true }
                    }
                }

                Section(header: Text("About"), footer: Text("Files you download from the PC are in the Files app › On My iPhone › AnyPC › From PC.")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Forget all PCs?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { store.removeAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to pair again with a PIN.")
            }
        }
        .navigationViewStyle(.stack)
    }
}
