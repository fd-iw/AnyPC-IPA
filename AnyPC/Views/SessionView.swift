import SwiftUI

/// Owns one connection and shows connecting → pairing → remote control.
struct SessionView: View {
    @StateObject private var conn: PCConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var suspended = false

    init(target: ConnectTarget) {
        _conn = StateObject(wrappedValue: PCConnection(target: target))
    }

    var body: some View {
        Group {
            switch conn.state {
            case .connected:
                RemoteView(conn: conn, onClose: close)
            case .needPair, .pairing:
                PairView(conn: conn, onCancel: close)
            case .failed(let message):
                StatusView(icon: "exclamationmark.triangle", title: "Can't connect", message: message,
                           primary: ("Try again", { conn.connect() }), secondary: ("Close", close))
            case .idle, .connecting:
                StatusView(icon: nil, title: suspended ? "Reconnecting…" : "Connecting to \(conn.serverName)…",
                           message: nil, primary: nil, secondary: ("Cancel", close))
            }
        }
        .onAppear { conn.connect() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                if conn.state == .connected || conn.state == .connecting {
                    conn.suspend()
                    suspended = true
                }
            case .active:
                if suspended {
                    suspended = false
                    conn.connect()
                }
            default:
                break
            }
        }
    }

    private func close() {
        conn.disconnect()
        dismiss()
    }
}

struct StatusView: View {
    let icon: String?
    let title: String
    let message: String?
    let primary: (String, () -> Void)?
    let secondary: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if let icon = icon {
                Image(systemName: icon).font(.system(size: 44)).foregroundColor(.orange)
            } else {
                ProgressView().scaleEffect(1.4)
            }
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            if let message = message {
                ScrollView {
                    Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxHeight: 220)
            }
            if let primary = primary {
                Button(primary.0, action: primary.1)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            if let secondary = secondary {
                Button(secondary.0, action: secondary.1)
            }
            Spacer()
        }
        .padding(24)
    }
}

/// PIN entry for a PC that doesn't know this phone yet.
struct PairView: View {
    @ObservedObject var conn: PCConnection
    let onCancel: () -> Void
    @State private var pin = ""
    @FocusState private var focused: Bool

    private var securityCode: String? {
        guard let fp = conn.seenFingerprint, fp.count >= 16 else { return nil }
        let chars = Array(fp.prefix(16).uppercased())
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: " ")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 44))
                        .foregroundColor(.accentColor)
                        .padding(.top, 12)
                    Text("Pair with \(conn.serverName)")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text("Enter the 6-digit PIN shown in the AnyPC window on your PC.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    TextField("000000", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                        .focused($focused)
                        .onChange(of: pin) { value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { pin = digits }
                            if digits.count == 6 && conn.state != .pairing { conn.pair(pin: digits) }
                        }

                    if let message = conn.pairMessage {
                        Text(message).font(.footnote).foregroundColor(.red).multilineTextAlignment(.center)
                    }

                    Button {
                        conn.pair(pin: pin)
                    } label: {
                        if conn.state == .pairing {
                            ProgressView()
                        } else {
                            Text("Pair").frame(maxWidth: 200)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(pin.count != 6 || conn.state == .pairing)

                    if let code = securityCode {
                        VStack(spacing: 4) {
                            Text("Security code").font(.caption).foregroundColor(.secondary)
                            Text(code).font(.system(.callout, design: .monospaced))
                            Text("It should match the code in the AnyPC window.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
        }
        .onChange(of: conn.pairMessage) { message in
            if message != nil { pin = "" }
        }
    }
}
