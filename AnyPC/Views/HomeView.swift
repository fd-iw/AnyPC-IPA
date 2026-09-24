import SwiftUI

/// Saved PCs, PCs found on the network, and ways to add one.
struct HomeView: View {
    @ObservedObject private var store = PCStore.shared
    @StateObject private var discovery = Discovery()
    @State private var target: ConnectTarget?
    @State private var showScanner = false
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var pendingTarget: ConnectTarget?

    private var unpaired: [Discovery.Found] {
        discovery.found.filter { f in !store.pcs.contains { $0.id == f.serverId } }
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("My PCs")) {
                    if store.pcs.isEmpty {
                        Text("No paired PCs yet. Install AnyPC on your Windows PC, then pick it below or scan its QR code.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(store.pcs) { pc in
                        Button {
                            target = ConnectTarget(saved: pc, endpoint: discovery.endpoint(for: pc.id))
                        } label: {
                            PCRow(name: pc.name, detail: pc.host, online: discovery.endpoint(for: pc.id) != nil, paired: true)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { store.pcs[$0].id }.forEach(store.remove)
                    }
                }

                Section(header: Text("Nearby"), footer: Text("PCs running AnyPC on this Wi-Fi network appear here.")) {
                    if unpaired.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching…").foregroundColor(.secondary)
                        }
                    }
                    ForEach(unpaired) { f in
                        Button {
                            target = ConnectTarget(name: f.name, hosts: [], fingerprint: f.fingerprint,
                                                   serverId: f.serverId, endpoint: f.endpoint)
                        } label: {
                            PCRow(name: f.name, detail: "Tap to pair", online: true, paired: false)
                        }
                    }
                }

                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add PC by IP address", systemImage: "plus.circle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("AnyPC")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { discovery.start() }
        .fullScreenCover(item: $target) { t in
            SessionView(target: t)
        }
        .sheet(isPresented: $showScanner, onDismiss: presentPending) {
            QRScannerSheet { code in
                if let t = ConnectTarget(qr: code) {
                    pendingTarget = t
                    showScanner = false
                }
            }
        }
        .sheet(isPresented: $showAdd, onDismiss: presentPending) {
            AddPCView { host, port in
                pendingTarget = ConnectTarget(name: host, hosts: [host], port: port)
                showAdd = false
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// A full-screen cover can only be presented once the sheet is gone.
    private func presentPending() {
        guard let t = pendingTarget else { return }
        pendingTarget = nil
        target = t
    }
}

private struct PCRow: View {
    let name: String
    let detail: String
    let online: Bool
    let paired: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).foregroundColor(.primary)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if paired {
                Circle()
                    .fill(online ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Add a PC manually by IP address.
struct AddPCView: View {
    let onConnect: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = String(Wire.defaultPort)

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("The IP address is shown in the AnyPC window on the PC, for example 192.168.1.20.")) {
                    TextField("IP address", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Add PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        onConnect(host.trimmingCharacters(in: .whitespaces), Int(port) ?? Wire.defaultPort)
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
