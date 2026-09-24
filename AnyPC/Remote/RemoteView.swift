import SwiftUI

/// Full-screen remote control: the PC screen plus a toolbar.
struct RemoteView: View {
    @ObservedObject var conn: PCConnection
    let onClose: () -> Void

    @AppStorage(Prefs.modeKey) private var modeRaw = ControlMode.trackpad.rawValue
    @AppStorage(Prefs.sensitivityKey) private var sensitivity = 1.3
    @State private var keyboardVisible = false
    @State private var sheet: RemoteSheet?
    @State private var showHelp = false

    private var mode: ControlMode { ControlMode(rawValue: modeRaw) ?? .trackpad }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                RemoteScreenRepresentable(conn: conn, mode: mode, sensitivity: CGFloat(sensitivity), keyboardVisible: $keyboardVisible)
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                if let toast = conn.toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            toolbar
        }
        .background(Color.black.ignoresSafeArea())
        .statusBar(hidden: true)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(item: $sheet, onDismiss: { conn.startStream() }) { which in
            switch which {
            case .files: FileBrowserView(conn: conn)
            case .system: SystemActionsView(conn: conn)
            case .settings: SettingsView()
            }
        }
        .alert(mode == .trackpad ? "Trackpad mode" : "Touch mode", isPresented: $showHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mode == .trackpad
                 ? "Drag to move the pointer • Tap to click • Two-finger tap to right-click • Hold, then drag to drag • Two-finger drag to scroll • Pinch to zoom"
                 : "Tap to click there • Long-press to right-click • Drag to drag • Two-finger drag to scroll (or move around when zoomed) • Pinch to zoom")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ToolbarButton(symbol: "keyboard", active: keyboardVisible) { keyboardVisible.toggle() }
            ToolbarButton(symbol: mode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.tap", active: false) {
                modeRaw = (mode == .trackpad ? ControlMode.touch : ControlMode.trackpad).rawValue
                conn.showToast(mode == .trackpad ? "Trackpad mode" : "Touch mode")
            }
            .simultaneousGesture(LongPressGesture().onEnded { _ in showHelp = true })
            if conn.monitors.count > 1 {
                Menu {
                    ForEach(conn.monitors) { m in
                        Button {
                            conn.startStream(monitor: m.id)
                        } label: {
                            if m.id == conn.currentMonitor {
                                Label("\(m.name)  \(m.width)×\(m.height)", systemImage: "checkmark")
                            } else {
                                Text("\(m.name)  \(m.width)×\(m.height)")
                            }
                        }
                    }
                } label: {
                    ToolbarIcon(symbol: "display.2", active: false)
                }
            }
            ToolbarButton(symbol: "folder", active: false) { sheet = .files }
            ToolbarButton(symbol: "power", active: false) { sheet = .system }
            ToolbarButton(symbol: "gearshape", active: false) { sheet = .settings }
            ToolbarButton(symbol: "xmark.circle", active: false, action: onClose)
        }
        .frame(height: 46)
        .background(Color(white: 0.1))
    }
}

enum RemoteSheet: String, Identifiable {
    case files, system, settings
    var id: String { rawValue }
}

private struct ToolbarIcon: View {
    let symbol: String
    let active: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19))
            .foregroundColor(active ? .accentColor : .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolbarIcon(symbol: symbol, active: active)
        }
    }
}

/// Bridges the UIKit screen view (gestures, keyboard) into SwiftUI.
struct RemoteScreenRepresentable: UIViewRepresentable {
    let conn: PCConnection
    let mode: ControlMode
    let sensitivity: CGFloat
    @Binding var keyboardVisible: Bool

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(conn: conn)
        view.keyboard.onText = { [weak conn] s in conn?.text(s) }
        view.keyboard.onKey = { [weak conn] vk, mods in conn?.key(vk, mods: mods) }
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        if view.mode != mode {
            view.mode = mode
            view.resetZoom()
        }
        view.sensitivity = sensitivity
        let binding = $keyboardVisible
        view.keyboard.onVisibilityChange = { visible in
            DispatchQueue.main.async {
                if binding.wrappedValue != visible { binding.wrappedValue = visible }
            }
        }
        if keyboardVisible && !view.keyboard.isFirstResponder {
            DispatchQueue.main.async { _ = view.keyboard.becomeFirstResponder() }
        } else if !keyboardVisible && view.keyboard.isFirstResponder {
            DispatchQueue.main.async { _ = view.keyboard.resignFirstResponder() }
        }
    }
}
