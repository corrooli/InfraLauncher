// Store: list, groups, processes, states.

import SwiftUI
import AppKit
import Darwin
import os

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var services: [Service] = [] { didSet { save(services, to: servicesURL) } }
    @Published var groups: [ServiceGroup] = [] { didSet { save(groups, to: groupsURL) } }
    @Published private(set) var states: [UUID: TunnelState] = [:]
    @Published private(set) var notes: [UUID: String] = [:]
    @Published private(set) var since: [UUID: Date] = [:]
    @Published private(set) var pendingOpen: Set<UUID> = []
    @Published var inputs: [UUID: String] = [:]
    @Published private(set) var recents: [UUID: [String]] = [:] {
        didSet {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: recents.map { ($0.key.uuidString, $0.value) }), forKey: "recentInputs")
        }
    }
    /// Collapsed sections: group ID or "ungrouped".
    @Published var collapsed: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedSections") }
    }

    private var processes: [UUID: Process] = [:]
    private var seenPorts: [UUID: Set<Int>] = [:]
    private var lastMessage: [UUID: String] = [:]
    private var buffers: [UUID: String] = [:]

    private static let dir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfraLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let servicesURL = Store.dir.appendingPathComponent("services.json")
    private let groupsURL = Store.dir.appendingPathComponent("groups.json")

    init() {
        let dec = JSONDecoder()
        if let data = try? Data(contentsOf: servicesURL),
           let list = try? dec.decode([Service].self, from: data) {
            services = list
            // Older versions had no groups; the list then stays ungrouped.
            if let data = try? Data(contentsOf: groupsURL),
               let g = try? dec.decode([ServiceGroup].self, from: data) {
                groups = g
            }
        } else {
            groups = ServiceGroup.defaults
            services = Service.defaults
        }
        let raw = UserDefaults.standard.dictionary(forKey: "recentInputs") as? [String: [String]] ?? [:]
        recents = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? [])
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(value).write(to: url, options: .atomic)
    }

    func state(_ id: UUID) -> TunnelState { states[id] ?? .idle }
    var activeCount: Int { states.values.filter(\.isActive).count }
    func group(_ id: UUID?) -> ServiceGroup? { id.flatMap { id in groups.first { $0.id == id } } }
    func services(in group: UUID?) -> [Service] { services.filter { $0.groupID == group } }

    /// Services shown by a sidebar item.
    func services(for item: SidebarItem) -> [Service] {
        switch item {
        case .all: services
        case .active: services.filter { state($0.id).isActive }
        case .web: services.filter { !$0.isTerminal }
        case .shells: services.filter(\.isTerminal)
        case .group(let id): services(in: id)
        }
    }

    // MARK: Editing

    func upsert(_ s: Service) {
        if let i = services.firstIndex(where: { $0.id == s.id }) {
            let changed = services[i].command != s.command
            services[i] = s
            // Running tunnel with changed ports: restart it so the change takes effect.
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
        recents[id] = nil
    }

    func duplicate(_ id: UUID) {
        guard let i = services.firstIndex(where: { $0.id == id }) else { return }
        var copy = services[i]
        copy.id = UUID()
        copy.name += " Copy"
        services.insert(copy, at: i + 1)
    }

    func restoreDefaults() {
        stopAll()
        states = [:]
        groups = ServiceGroup.defaults
        services = Service.defaults
    }

    // MARK: Order and groups

    /// Moves `id` to the position of `target`. With `adoptGroup` the service also moves
    /// into the target's group (dragging between sections).
    func move(_ id: UUID, to target: UUID, adoptGroup: Bool) {
        guard id != target,
              let from = services.firstIndex(where: { $0.id == id }),
              let to = services.firstIndex(where: { $0.id == target }) else { return }
        var list = services
        var item = list.remove(at: from)
        if adoptGroup { item.groupID = services[to].groupID }
        list.insert(item, at: to)
        services = list
    }

    /// Appends a service to the end of a group (nil = no group).
    func assign(_ id: UUID, to group: UUID?) {
        guard let i = services.firstIndex(where: { $0.id == id }) else { return }
        if services[i].groupID == group { return }
        var list = services
        var item = list.remove(at: i)
        item.groupID = group
        list.append(item)
        services = list
    }

    func upsertGroup(_ g: ServiceGroup) {
        if let i = groups.firstIndex(where: { $0.id == g.id }) { groups[i] = g } else { groups.append(g) }
    }

    /// Deletes only the group; its services are kept without a group.
    func deleteGroup(_ id: UUID) {
        services = services.map { var s = $0; if s.groupID == id { s.groupID = nil }; return s }
        groups.removeAll { $0.id == id }
        collapsed.remove(id.uuidString)
    }

    func moveGroups(from: IndexSet, to: Int) { groups.move(fromOffsets: from, toOffset: to) }

    func toggleCollapsed(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    func startAll(_ list: [Service]) {
        for s in list where !s.isTerminal && s.placeholder == nil && !state(s.id).isActive { start(s) }
    }

    func stopAll(_ list: [Service]) {
        for s in list { stop(s.id) }
    }

    // MARK: Tunnel

    func start(_ s: Service) {
        guard processes[s.id] == nil, !s.isTerminal, let cmd = resolvedCommand(s) else { return }
        let id = s.id
        for port in s.localPorts where Self.portInUse(port) {
            states[id] = .failed("Port \(port) is already in use")
            pendingOpen.remove(id)
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
        // Only evaluate the exit once the process is gone AND stderr is fully read –
        // otherwise the last line is missing, and that's the one saying why ssh gave up.
        let finished = DispatchGroup()
        finished.enter()
        finished.enter()
        let eof = OSAllocatedUnfairLock(initialState: false)  // calling leave() twice would crash
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

        // Without recognizable -L ports, "still running" counts as connected.
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
        pendingOpen.remove(id)
        notes[id] = nil
        since[id] = nil
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

    func toggle(_ s: Service) {
        state(s.id).isActive ? stop(s.id) : start(s)
    }

    func open(_ s: Service) {
        if s.isTerminal { openTerminal(s); return }
        switch state(s.id) {
        case .up: openURLs(s.id)
        case .connecting: pendingOpen.insert(s.id)
        case .idle, .failed:
            pendingOpen.insert(s.id)
            start(s)
            if processes[s.id] == nil { pendingOpen.remove(s.id) }
        }
    }

    // MARK: Internal

    private func resolvedCommand(_ s: Service) -> String? {
        var cmd = s.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ph = s.placeholder {
            let value = (inputs[s.id] ?? "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else {
                states[s.id] = .failed("Enter \(ph) first")
                return nil
            }
            cmd = cmd.replacingOccurrences(of: ph, with: value)
            remember(value, for: s.id)
        }
        if case .failed = state(s.id) { states[s.id] = .idle }
        return cmd
    }

    private func remember(_ value: String, for id: UUID) {
        var list = recents[id] ?? []
        list.removeAll { $0 == value }
        list.insert(value, at: 0)
        recents[id] = Array(list.prefix(6))
    }

    private func consume(_ text: String, id: UUID, process: Process, expected: Set<Int>) {
        guard processes[id] === process else { return }
        // ssh logs with "\r\n"; to Swift that's ONE character and never equal to "\n".
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
        // ssh -v reports every locally bound port: "Local forwarding listening on ::1 port 8006."
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
        since[id] = Date()
        if pendingOpen.remove(id) != nil { openURLs(id) }
    }

    private func exited(id: UUID, process: Process, code: Int32) {
        guard processes[id] === process else { return }
        if let rest = buffers[id], !rest.isEmpty {
            handle(rest.trimmingCharacters(in: .whitespacesAndNewlines), id: id, expected: [])
        }
        processes[id] = nil
        pendingOpen.remove(id)
        notes[id] = nil
        since[id] = nil
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
            let app = TerminalApp.current
            app.run(script: url) { [weak self] err in
                MainActor.assumeIsolated {
                    if err != nil { self?.states[s.id] = .failed("Couldn’t open \(app.name)") }
                }
            }
        } catch {
            states[s.id] = .failed(error.localizedDescription)
        }
    }

    private static func isSSH(_ cmd: String) -> Bool { cmd.hasPrefix("ssh ") }

    /// Options for a tunnel without a terminal: no prompt, abort on port errors,
    /// keepalive, and -v so the bound ports can be detected.
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

    /// Checks with bind instead of connect – a connect through someone else's
    /// tunnel would open a connection to its target.
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

// MARK: - UI state

@MainActor
final class UIState: ObservableObject {
    static let shared = UIState()

    @Published var selection: SidebarItem {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: "sidebarSelection") }
    }
    @Published var viewMode: ViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var editingService: Service?
    @Published var editingGroup: ServiceGroup?
    @Published var pendingDelete: Service?
    @Published var confirmRestore = false
    /// Service that moves into a new group once it's created.
    var assignToNewGroup: UUID?

    init() {
        selection = UserDefaults.standard.string(forKey: "sidebarSelection").flatMap(SidebarItem.init(rawValue:)) ?? .all
        viewMode = UserDefaults.standard.string(forKey: "viewMode").flatMap(ViewMode.init(rawValue:)) ?? .grid
    }

    func newService() {
        editingService = Service(name: "", command: "ssh -N -L ", urls: [], groupID: selection.groupID)
    }

    func newGroup(moving service: UUID? = nil) {
        assignToNewGroup = service
        let used = Set(Store.shared.groups.map(\.color))
        let color = Palette.swatches.map(\.key).first { !used.contains($0) } ?? "blue"
        editingGroup = ServiceGroup(name: "", symbol: "folder.fill", color: color)
    }
}

// MARK: - Drag and drop

/// Remembers which service is being dragged. SwiftUI doesn't report the end of a
/// drag when it's dropped elsewhere – hence the mouse button check.
@MainActor
final class DragState: ObservableObject {
    @Published private(set) var id: UUID?
    private var timer: Timer?

    func begin(_ id: UUID) {
        self.id = id
        timer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.end() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func end() {
        timer?.invalidate()
        timer = nil
        if id != nil { withAnimation(.easeOut(duration: 0.2)) { id = nil } }
    }
}
