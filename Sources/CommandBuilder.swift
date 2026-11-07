// Simple mode in the editor: enter target, port and SSH host, and the command writes itself.

import SwiftUI

struct SimpleSpec: Equatable {
    enum Kind: String { case web, shell }

    var kind: Kind = .web
    /// Target as seen from the SSH host (web), or the server for a shell.
    var host = ""
    var port = ""
    var scheme = "https"
    var path = ""
    /// Empty = choose automatically.
    var localPort = ""
    /// SSH host to go through. Optional for shells (empty = direct).
    var jump = ""
    var user = ""
    var sshPort = ""
    /// Host is asked for when opening (<host>).
    var askHost = false
    /// Name of the placeholder, e.g. <ip> from an existing command.
    var askName = "<host>"

    var hostValue: String { askHost ? askName : host.trimmingCharacters(in: .whitespaces) }

    var isComplete: Bool {
        switch kind {
        case .web: !hostValue.isEmpty && Int(port) != nil && !jump.trimmingCharacters(in: .whitespaces).isEmpty
        case .shell: !hostValue.isEmpty
        }
    }

    /// Local port: as entered, otherwise the target port (below 1024 → 8000+port), then the next free one.
    func resolvedLocalPort(taken: Set<Int>) -> Int? {
        if let p = Int(localPort.trimmingCharacters(in: .whitespaces)) { return p }
        guard let target = Int(port) else { return nil }
        var p = target < 1024 ? 8000 + target : target
        while taken.contains(p) && p < 65535 { p += 1 }
        return p
    }

    func build(taken: Set<Int>) -> (command: String, urls: [String]) {
        let jump = jump.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .web:
            let lp = resolvedLocalPort(taken: taken).map(String.init) ?? "PORT"
            let cmd = "ssh -N -L \(lp):\(hostValue.isEmpty ? "HOST" : hostValue):\(port.isEmpty ? "PORT" : port) \(jump.isEmpty ? "SSH-HOST" : jump)"
            var p = path.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty && !p.hasPrefix("/") { p = "/" + p }
            return (cmd, ["\(scheme)://localhost:\(lp)\(p)"])
        case .shell:
            var parts = ["ssh"]
            if !jump.isEmpty { parts += ["-J", jump] }
            if let sp = Int(sshPort), sp != 22 { parts += ["-p", String(sp)] }
            let u = user.trimmingCharacters(in: .whitespaces)
            let h = hostValue.isEmpty ? "HOST" : hostValue
            parts.append(u.isEmpty ? h : "\(u)@\(h)")
            return (parts.joined(separator: " "), [])
        }
    }

    /// Recognizes commands that simple mode would generate itself. Everything else stays in raw mode.
    static func parse(command: String, urls: [String]) -> SimpleSpec? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if urls.count == 1,
           let m = cmd.firstMatch(of: #/^ssh\s+-N\s+-L\s+(\d+):([^:\s]+):(\d+)\s+([^\s-][^\s]*)$/#),
           let u = urls[0].firstMatch(of: #/^(https?):\/\/localhost:(\d+)(\/.*)?$/#),
           u.2 == m.1 {
            var s = SimpleSpec(kind: .web)
            s.localPort = String(m.1)
            s.host = String(m.2)
            s.port = String(m.3)
            s.jump = String(m.4)
            s.scheme = String(u.1)
            s.path = u.3.map(String.init) ?? ""
            s.normalizeHost()
            return s
        }
        if urls.isEmpty,
           let m = cmd.firstMatch(of: #/^ssh(?:\s+-J\s+(\S+))?(?:\s+-p\s+(\d+))?\s+(?:([^@\s-][^@\s]*)@)?([^\s@-][^\s@]*)$/#) {
            var s = SimpleSpec(kind: .shell)
            s.jump = m.1.map(String.init) ?? ""
            s.sshPort = m.2.map(String.init) ?? ""
            s.user = m.3.map(String.init) ?? ""
            s.host = String(m.4)
            s.normalizeHost()
            return s
        }
        return nil
    }

    private mutating func normalizeHost() {
        if host.hasPrefix("<") && host.hasSuffix(">") {
            askHost = true
            askName = host
            host = ""
        }
    }

    /// SSH hosts from existing entries, most frequent first.
    static func knownJumpHosts(in services: [Service]) -> [String] {
        var count: [String: Int] = [:]
        for s in services {
            let t = s.command.split(whereSeparator: \.isWhitespace).map(String.init)
            if let i = t.firstIndex(of: "-J"), i + 1 < t.count { count[t[i + 1], default: 0] += 1 }
            if t.contains("-N"), !t.contains("-J"), let last = t.last, !last.hasPrefix("-") { count[last, default: 0] += 1 }
        }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

struct SimpleBuilder: View {
    @Binding var spec: SimpleSpec
    let jumpHosts: [String]
    let takenPorts: Set<Int>

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                label("Type")
                Picker("", selection: $spec.kind.animation(.snappy)) {
                    Text("Web Interface").tag(SimpleSpec.Kind.web)
                    Text("Shell").tag(SimpleSpec.Kind.shell)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if spec.kind == .web { webRows } else { shellRows }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private var webRows: some View {
        GridRow {
            label("Service")
            HStack(spacing: 6) {
                Picker("", selection: $spec.scheme) {
                    Text("https://").tag("https")
                    Text("http://").tag("http")
                }
                .labelsHidden()
                .fixedSize()
                hostField(prompt: "192.168.1.10")
                Text(":").foregroundStyle(.secondary)
                TextField("", text: $spec.port, prompt: Text(verbatim: "8006"))
                    .frame(width: 64)
                TextField("", text: $spec.path, prompt: Text("/path"))
                    .frame(width: 78)
            }
        }
        hint("Address and port as the SSH host sees it. Use localhost for something running on the SSH host itself.")
        GridRow {
            label("Through")
            jumpField(prompt: "jumphost or user@host")
        }
        hint("The SSH server that can reach the service. Aliases from ~/.ssh/config work.")
        GridRow {
            label("Local port")
            HStack(spacing: 8) {
                TextField("", text: $spec.localPort, prompt: Text(verbatim: spec.localPort.isEmpty ? (spec.resolvedLocalPort(taken: takenPorts).map { "\($0)" } ?? "auto") : ""))
                    .frame(width: 80)
                if let url = spec.build(taken: takenPorts).urls.first, spec.isComplete {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 10))
                        Text(verbatim: url)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder private var shellRows: some View {
        GridRow {
            label("Server")
            HStack(spacing: 6) {
                TextField("", text: $spec.user, prompt: Text("user"))
                    .frame(width: 90)
                Text("@").foregroundStyle(.secondary)
                hostField(prompt: "192.168.1.40")
            }
        }
        GridRow {
            label("Port")
            TextField("", text: $spec.sshPort, prompt: Text(verbatim: "22"))
                .frame(width: 64)
        }
        GridRow {
            label("Jump host")
            jumpField(prompt: "None – connect directly")
        }
        hint("Leave empty for a direct connection, or name the host to hop through.")
    }

    private func hostField(prompt: String) -> some View {
        HStack(spacing: 6) {
            if spec.askHost {
                Text("Asked when opening")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            } else {
                TextField("", text: $spec.host, prompt: Text(verbatim: prompt))
                    .frame(minWidth: 120, maxWidth: .infinity)
            }
            Toggle(isOn: $spec.askHost.animation(.snappy)) {
                Image(systemName: "questionmark.bubble")
            }
            .toggleStyle(.button)
            .help("Ask for the host each time you open it")
        }
    }

    private func jumpField(prompt: String) -> some View {
        HStack(spacing: 4) {
            TextField("", text: $spec.jump, prompt: Text(prompt))
                .frame(maxWidth: .infinity)
            if !jumpHosts.isEmpty {
                Menu {
                    ForEach(jumpHosts, id: \.self) { h in
                        Button(h) { spec.jump = h }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Hosts you already use")
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func hint(_ s: String) -> some View {
        GridRow {
            Text(verbatim: "")
            Text(s)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, -6)
        }
    }
}
