// InfraLauncher – kleine Mac-App: SSH-Tunnel starten und den Dienst im Browser öffnen.
// Gebaut mit build.sh, ohne Xcode-Projekt.

import SwiftUI
import AppKit
import Darwin
import os

// MARK: - Modell

struct Service: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    var urls: [String]

    /// Terminal-Einträge haben keine URL und öffnen stattdessen eine Shell.
    var isTerminal: Bool { urls.isEmpty }

    /// Weiterleitungen aus allen -L-Argumenten: (lokaler Port, Ziel).
    var forwards: [(port: Int, target: String)] {
        let pattern = #"-L\s*(?:[A-Za-z0-9.\-]+:)?(\d+):(\S+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = command as NSString
        return re.matches(in: command, range: NSRange(location: 0, length: ns.length)).compactMap {
            guard let port = Int(ns.substring(with: $0.range(at: 1))) else { return nil }
            return (port, ns.substring(with: $0.range(at: 2)))
        }
    }

    var localPorts: [Int] { forwards.map(\.port) }

    /// Erster Platzhalter wie <ip>, der in der Zeile abgefragt wird.
    var placeholder: String? {
        guard let r = command.range(of: #"<[^<>\s]+>"#, options: .regularExpression) else { return nil }
        return String(command[r])
    }

    var summary: String {
        if isTerminal { return command }
        let f = forwards
        return f.isEmpty ? command : f.map { ":\($0.port) → \($0.target)" }.joined(separator: "  ·  ")
    }
}

enum TunnelState: Equatable {
    case idle, connecting, up, failed(String)

    var isActive: Bool { self == .connecting || self == .up }
}

extension Service {
    /// Beispiele für den ersten Start. "jumphost" ist ein Host-Alias aus ~/.ssh/config.
    static let defaults: [Service] = [
        Service(name: "Proxmox", command: "ssh -N -L 8006:192.168.1.10:8006 jumphost", urls: ["https://localhost:8006"]),
        Service(name: "Grafana + Prometheus", command: "ssh -N -L 3000:192.168.1.20:3000 -L 9090:192.168.1.20:9090 jumphost", urls: ["http://localhost:3000", "http://localhost:9090"]),
        Service(name: "NAS (Synology DSM)", command: "ssh -N -L 5001:nas.lan:5001 jumphost", urls: ["https://localhost:5001"]),
        Service(name: "Admin UI only on localhost", command: "ssh -N -J jumphost -L 8081:127.0.0.1:81 admin@192.168.1.30", urls: ["http://localhost:8081"]),
        Service(name: "Shell on app server", command: "ssh -J jumphost admin@192.168.1.40", urls: []),
        Service(name: "Shell on any host", command: "ssh -J jumphost root@<ip>", urls: []),
    ]
}

// MARK: - Store: Liste, Prozesse, Zustände

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var services: [Service] = [] { didSet { save() } }
    @Published private(set) var states: [UUID: TunnelState] = [:]
    @Published private(set) var notes: [UUID: String] = [:]
    @Published var inputs: [UUID: String] = [:]

    private var processes: [UUID: Process] = [:]
    private var openWhenUp: Set<UUID> = []
    private var seenPorts: [UUID: Set<Int>] = [:]
    private var lastMessage: [UUID: String] = [:]
    private var buffers: [UUID: String] = [:]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfraLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("services.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Service].self, from: data) {
            services = list
        } else {
            services = Service.defaults
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(services).write(to: fileURL, options: .atomic)
    }

    func state(_ id: UUID) -> TunnelState { states[id] ?? .idle }
    var activeCount: Int { states.values.filter(\.isActive).count }

    // MARK: Bearbeiten

    func upsert(_ s: Service) {
        if let i = services.firstIndex(where: { $0.id == s.id }) {
            let changed = services[i].command != s.command
            services[i] = s
            // Laufender Tunnel mit geänderten Ports: neu starten, damit es gilt.
            if changed && state(s.id).isActive {
                stop(s.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { self.start(s) }
                }
            }
        } else {
            services.append(s)
        }
    }

    func delete(_ id: UUID) {
        stop(id)
        services.removeAll { $0.id == id }
        states[id] = nil
    }

    func restoreDefaults() {
        stopAll()
        states = [:]
        services = Service.defaults
    }

    // MARK: Tunnel

    func start(_ s: Service) {
        guard processes[s.id] == nil, !s.isTerminal, let cmd = resolvedCommand(s) else { return }
        let id = s.id
        for port in s.localPorts where Self.portInUse(port) {
            states[id] = .failed("Port \(port) is already in use")
            openWhenUp.remove(id)
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec " + Self.prepared(cmd)]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err

        let expected = Set(s.localPorts)
        // Ende erst auswerten, wenn der Prozess weg UND stderr vollständig gelesen ist –
        // sonst fehlt die letzte Zeile, und genau die sagt, warum ssh aufgegeben hat.
        let finished = DispatchGroup()
        finished.enter()
        finished.enter()
        let eof = OSAllocatedUnfairLock(initialState: false)  // doppeltes leave() wäre ein Absturz
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                if eof.withLock({ let first = !$0; $0 = true; return first }) { finished.leave() }
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(text, id: id, process: p, expected: expected) }
            }
        }
        p.terminationHandler = { _ in finished.leave() }
        finished.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.exited(id: id, process: p, code: p.terminationStatus) }
        }

        do { try p.run() } catch {
            states[id] = .failed(error.localizedDescription)
            return
        }
        processes[id] = p
        seenPorts[id] = []
        lastMessage[id] = nil
        buffers[id] = ""
        notes[id] = nil
        states[id] = .connecting

        // Ohne erkennbare -L-Ports: "läuft noch" gilt als verbunden.
        let watchPorts = !expected.isEmpty && Self.isSSH(cmd)
        DispatchQueue.main.asyncAfter(deadline: .now() + (watchPorts ? 25 : 1.5)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.processes[id] === p, self.state(id) == .connecting else { return }
                if watchPorts {
                    self.stop(id)
                    self.states[id] = .failed("Timed out")
                } else {
                    self.markUp(id)
                }
            }
        }
    }

    func stop(_ id: UUID) {
        openWhenUp.remove(id)
        notes[id] = nil
        guard let p = processes.removeValue(forKey: id) else {
            if case .failed = state(id) { states[id] = .idle }
            return
        }
        states[id] = .idle
        p.terminate()
    }

    func stopAll() {
        for id in Array(processes.keys) { stop(id) }
    }

    func open(_ s: Service) {
        if s.isTerminal { openTerminal(s); return }
        switch state(s.id) {
        case .up: openURLs(s.id)
        case .connecting: openWhenUp.insert(s.id)
        case .idle, .failed:
            openWhenUp.insert(s.id)
            start(s)
        }
    }

    // MARK: Intern

    private func resolvedCommand(_ s: Service) -> String? {
        var cmd = s.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ph = s.placeholder {
            let value = (inputs[s.id] ?? "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else {
                states[s.id] = .failed("Enter \(ph) first")
                return nil
            }
            cmd = cmd.replacingOccurrences(of: ph, with: value)
        }
        if case .failed = state(s.id) { states[s.id] = .idle }
        return cmd
    }

    private func consume(_ text: String, id: UUID, process: Process, expected: Set<Int>) {
        guard processes[id] === process else { return }
        // ssh loggt mit "\r\n"; für Swift ist das EIN Zeichen und nie gleich "\n".
        var buf = (buffers[id] ?? "") + text.replacingOccurrences(of: "\r", with: "")
        while let nl = buf.firstIndex(of: "\n") {
            let line = buf[..<nl].trimmingCharacters(in: .whitespacesAndNewlines)
            buf = String(buf[buf.index(after: nl)...])
            handle(line, id: id, expected: expected)
        }
        buffers[id] = buf
    }

    private func handle(_ line: String, id: UUID, expected: Set<Int>) {
        guard !line.isEmpty else { return }
        // ssh -v meldet jeden lokal gebundenen Port: "Local forwarding listening on ::1 port 8006."
        if line.contains("Local forwarding listening on"),
           let r = line.range(of: #"port (\d+)"#, options: .regularExpression),
           let port = Int(line[r].dropFirst(5)) {
            seenPorts[id, default: []].insert(port)
            if expected.isSubset(of: seenPorts[id] ?? []), state(id) == .connecting { markUp(id) }
            return
        }
        guard !line.hasPrefix("debug"), !line.hasPrefix("OpenSSH_"), !line.hasPrefix("Authenticated to"), !line.hasPrefix("Transferred"), !line.hasPrefix("Warning: Permanently") else { return }
        lastMessage[id] = line
        if state(id) == .up, line.contains("open failed") {
            notes[id] = "Target unreachable: " + (line.components(separatedBy: "open failed: ").last ?? line)
        }
    }

    private func markUp(_ id: UUID) {
        states[id] = .up
        if openWhenUp.remove(id) != nil { openURLs(id) }
    }

    private func exited(id: UUID, process: Process, code: Int32) {
        guard processes[id] === process else { return }
        if let rest = buffers[id], !rest.isEmpty {
            handle(rest.trimmingCharacters(in: .whitespacesAndNewlines), id: id, expected: [])
        }
        processes[id] = nil
        openWhenUp.remove(id)
        notes[id] = nil
        states[id] = .failed(Self.friendly(lastMessage[id]) ?? "ssh exited (\(code))")
    }

    private func openURLs(_ id: UUID) {
        guard let s = services.first(where: { $0.id == id }) else { return }
        for u in s.urls.compactMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
    }

    private func openTerminal(_ s: Service) {
        guard let cmd = resolvedCommand(s) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("infralauncher-\(s.id.uuidString.prefix(8)).command")
        do {
            try "#!/bin/zsh\nclear\n\(cmd)\n".write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
            NSWorkspace.shared.open(url)
        } catch {
            states[s.id] = .failed(error.localizedDescription)
        }
    }

    private static func isSSH(_ cmd: String) -> Bool { cmd.hasPrefix("ssh ") }

    /// Optionen für einen Tunnel ohne Terminal: kein Prompt, Abbruch bei Portfehler,
    /// Keepalive, und -v, damit die gebundenen Ports erkennbar sind.
    private static func prepared(_ cmd: String) -> String {
        guard isSSH(cmd) else { return cmd }
        let opts = "-v -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
        return "ssh \(opts) " + cmd.dropFirst(4)
    }

    private static func friendly(_ msg: String?) -> String? {
        guard let msg else { return nil }
        let map = [
            "Permission denied": "Permission denied – key not accepted",
            "Host key verification failed": "Unknown host key – connect once in Terminal",
            "timed out": "Host unreachable (timeout)",
            "No route to host": "No route to host",
            "Connection refused": "Connection refused",
            "Address already in use": "Local port already in use",
            "Could not resolve": "Could not resolve host",
        ]
        return map.first { msg.localizedCaseInsensitiveContains($0.key) }?.value ?? msg
    }

    /// Belegt-Prüfung per bind statt connect – ein connect würde durch einen
    /// fremden Tunnel eine Verbindung zum Ziel aufbauen.
    static func portInUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc != 0
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Keine verwaisten ssh-Prozesse, die Ports blockieren.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Store.shared.stopAll() }
    }
}

@main
struct InfraLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        Window("InfraLauncher", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 560, height: 720)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Stop All Tunnels") { store.stopAll() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Restore Default Services") { store.restoreDefaults() }
            }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: Service?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(store.services) { s in
                    ServiceRow(service: s) { editing = s }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("InfraLauncher")
        .navigationSubtitle(store.activeCount == 0 ? "No active tunnels" : "\(store.activeCount) active")
        .toolbar {
            ToolbarItemGroup {
                Button { store.stopAll() } label: { Label("Stop All", systemImage: "stop.circle") }
                    .help("Stop all tunnels")
                    .disabled(store.activeCount == 0)
                Button { editing = Service(name: "", command: "ssh -N -L ", urls: []) } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add service")
            }
        }
        .sheet(item: $editing) { s in
            EditorView(original: s).environmentObject(store)
        }
    }
}

struct ServiceRow: View {
    @EnvironmentObject private var store: Store
    let service: Service
    let edit: () -> Void
    @State private var hover = false

    private var state: TunnelState { store.state(service.id) }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(state: service.isTerminal ? nil : state)

            VStack(alignment: .leading, spacing: 3) {
                Text(service.name)
                    .font(.system(size: 13, weight: .semibold))
                detail
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button(action: edit) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Edit command and ports")
                .opacity(hover ? 1 : 0)

            if let ph = service.placeholder {
                TextField(ph, text: Binding(
                    get: { store.inputs[service.id] ?? "" },
                    set: { store.inputs[service.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 120)
                    .onSubmit { store.open(service) }
            }

            if !service.isTerminal {
                Toggle("", isOn: Binding(
                    get: { state.isActive },
                    set: { $0 ? store.start(service) : store.stop(service.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(state.isActive ? "Stop tunnel" : "Start tunnel")
            }

            Button { store.open(service) } label: {
                Image(systemName: service.isTerminal ? "terminal" : "arrow.up.forward.app")
                    .frame(width: 18, height: 16)
            }
            .controlSize(.regular)
            .help(service.isTerminal ? "Open in Terminal" : "Connect and open in browser")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state == .up ? Color.green.opacity(0.45) : Color.primary.opacity(0.08))
        )
        .onHover { hover = $0 }
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(service.command, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(service.id) }
        }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    @ViewBuilder private var detail: some View {
        switch state {
        case .failed(let msg):
            Text(msg).foregroundStyle(.red)
        case .connecting:
            Text("Connecting…").foregroundStyle(.orange)
        default:
            if let note = store.notes[service.id] {
                Text(note).foregroundStyle(.orange)
            } else {
                Text(service.summary).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusDot: View {
    /// nil = Terminal-Eintrag ohne Zustand.
    let state: TunnelState?

    var body: some View {
        TimelineView(.animation(paused: state != .connecting)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                if let state {
                    Circle()
                        .fill(color(state))
                        .opacity(state == .connecting ? 0.55 + 0.45 * sin(t * 5) : 1)
                        .shadow(color: state == .up ? .green.opacity(0.8) : .clear, radius: 4)
                } else {
                    Circle().strokeBorder(Color.gray.opacity(0.5), lineWidth: 1.5)
                }
            }
            .frame(width: 9, height: 9)
        }
    }

    private func color(_ s: TunnelState) -> Color {
        switch s {
        case .idle: Color.gray.opacity(0.35)
        case .connecting: .orange
        case .up: .green
        case .failed: .red
        }
    }
}

struct EditorView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Service
    @State private var urlText: String

    init(original: Service) {
        _draft = State(initialValue: original)
        _urlText = State(initialValue: original.urls.joined(separator: "\n"))
    }

    private var isNew: Bool { !store.services.contains { $0.id == draft.id } }
    private var ports: String {
        let p = draft.localPorts
        return p.isEmpty ? "none found" : p.map { ":\($0)" }.joined(separator: "  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Service" : "Edit Service")
                .font(.title3.weight(.semibold))

            field("Name") {
                TextField("Grafana", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            field("Command", hint: "Local ports: \(ports)   ·   use <name> for a value asked in the row") {
                TextField("ssh -N -L 8080:192.168.1.50:80 jumphost", text: $draft.command, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2...5)
            }

            field("Open", hint: "One URL per line. Empty = open in Terminal instead.") {
                TextField("http://localhost:8080", text: $urlText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...4)
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        store.delete(draft.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespaces)
                    draft.command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.urls = urlText.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    store.upsert(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || draft.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 500)
    }

    private func field<C: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }
}
