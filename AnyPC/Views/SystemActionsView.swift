import SwiftUI

/// Power, volume and media controls.
struct SystemActionsView: View {
    @ObservedObject var conn: PCConnection
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: PowerAction?

    struct PowerAction: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let destructive: Bool
    }

    private let power: [PowerAction] = [
        PowerAction(id: "lock", title: "Lock", symbol: "lock", destructive: false),
        PowerAction(id: "sleep", title: "Sleep", symbol: "moon", destructive: true),
        PowerAction(id: "signout", title: "Sign out", symbol: "rectangle.portrait.and.arrow.right", destructive: true),
        PowerAction(id: "restart", title: "Restart", symbol: "arrow.clockwise", destructive: true),
        PowerAction(id: "shutdown", title: "Shut down", symbol: "power", destructive: true),
    ]

    private let media: [(String, String, String)] = [
        ("volume_down", "Volume −", "speaker.wave.1"),
        ("mute", "Mute", "speaker.slash"),
        ("volume_up", "Volume +", "speaker.wave.3"),
        ("prev_track", "Previous", "backward.end"),
        ("play_pause", "Play/Pause", "playpause"),
        ("next_track", "Next", "forward.end"),
    ]

    private let tools: [(String, String, String)] = [
        ("show_desktop", "Show desktop", "macwindow.on.rectangle"),
        ("task_manager", "Task Manager", "list.bullet.rectangle"),
    ]

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Sound & media") {
                        ForEach(media, id: \.0) { item in
                            ActionTile(title: item.1, symbol: item.2, tint: .accentColor) { conn.system(item.0) }
                        }
                    }
                    section("Windows") {
                        ForEach(tools, id: \.0) { item in
                            ActionTile(title: item.1, symbol: item.2, tint: .accentColor) {
                                conn.system(item.0)
                                dismiss()
                            }
                        }
                    }
                    section("Power") {
                        ForEach(power) { action in
                            ActionTile(title: action.title, symbol: action.symbol, tint: action.destructive ? .red : .accentColor) {
                                if action.destructive { confirm = action } else { conn.system(action.id) }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("\(conn.serverName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(confirm.map { "\($0.title) \(conn.serverName)?" } ?? "",
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                if let action = confirm {
                    Button(action.title, role: .destructive) {
                        conn.system(action.id)
                        confirm = nil
                    }
                }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: {
                Text("Unsaved work on the PC may be lost.")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, spacing: 12) { content() }
        }
    }
}

private struct ActionTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundColor(tint)
                Text(title).font(.caption).foregroundColor(.primary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}
