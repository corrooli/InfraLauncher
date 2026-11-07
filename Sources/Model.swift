// Data model: services, groups, states, colors and symbols.

import SwiftUI

struct Service: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    var urls: [String]
    /// SF Symbol; nil = guessed from the name.
    var symbol: String?
    /// Key from `Palette`; nil = automatic.
    var color: String?
    var groupID: UUID?

    /// Terminal entries have no URL and open a shell instead.
    var isTerminal: Bool { urls.isEmpty }

    /// Forwards from all -L arguments: (local port, target).
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

    /// First placeholder like <ip>, asked for when opening.
    var placeholder: String? {
        guard let r = command.range(of: #"<[^<>\s]+>"#, options: .regularExpression) else { return nil }
        return String(command[r])
    }

    var summary: String {
        if isTerminal { return command }
        let f = forwards
        return f.isEmpty ? command : f.map { ":\($0.port) → \($0.target)" }.joined(separator: "  ·  ")
    }

    /// Short form for tiles: just the local ports.
    var shortSummary: String {
        if isTerminal { return "Terminal" }
        let p = localPorts
        return p.isEmpty ? "Tunnel" : p.map { ":\($0)" }.joined(separator: " ")
    }

    var resolvedSymbol: String { symbol ?? Appearance.guess(for: self).symbol }
    var resolvedColor: String { color ?? Appearance.guess(for: self).color }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return ([name, command] + urls).contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

struct ServiceGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String = "folder.fill"
    var color: String = "blue"
}

enum TunnelState: Equatable {
    case idle, connecting, up, failed(String)

    var isActive: Bool { self == .connecting || self == .up }
}

// MARK: - Examples

extension ServiceGroup {
    static let defaults: [ServiceGroup] = [
        ServiceGroup(id: UUID(uuidString: "A1F0C2D4-0001-4000-8000-000000000001")!, name: "Infrastructure", symbol: "server.rack", color: "indigo"),
        ServiceGroup(id: UUID(uuidString: "A1F0C2D4-0002-4000-8000-000000000002")!, name: "Monitoring", symbol: "chart.bar.fill", color: "orange"),
        ServiceGroup(id: UUID(uuidString: "A1F0C2D4-0003-4000-8000-000000000003")!, name: "Shells", symbol: "terminal.fill", color: "graphite"),
    ]
}

extension Service {
    /// Examples for the first launch. "jumphost" is a host alias from ~/.ssh/config.
    static var defaults: [Service] {
        let g = ServiceGroup.defaults.map(\.id)
        return [
            Service(name: "Proxmox", command: "ssh -N -L 8006:192.168.1.10:8006 jumphost", urls: ["https://localhost:8006"], groupID: g[0]),
            Service(name: "NAS (Synology DSM)", command: "ssh -N -L 5001:nas.lan:5001 jumphost", urls: ["https://localhost:5001"], groupID: g[0]),
            Service(name: "Admin UI only on localhost", command: "ssh -N -J jumphost -L 8081:127.0.0.1:81 admin@192.168.1.30", urls: ["http://localhost:8081"], groupID: g[0]),
            Service(name: "Grafana + Prometheus", command: "ssh -N -L 3000:192.168.1.20:3000 -L 9090:192.168.1.20:9090 jumphost", urls: ["http://localhost:3000", "http://localhost:9090"], groupID: g[1]),
            Service(name: "Shell on app server", command: "ssh -J jumphost admin@192.168.1.40", urls: [], groupID: g[2]),
            Service(name: "Shell on any host", command: "ssh -J jumphost root@<ip>", urls: [], groupID: g[2]),
        ]
    }
}

// MARK: - Colors

enum Palette {
    struct Swatch: Identifiable {
        let key: String
        let name: String
        let top: Color
        let bottom: Color
        var id: String { key }
        var tint: Color { bottom }
        var gradient: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom) }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    static let swatches: [Swatch] = [
        Swatch(key: "red", name: "Red", top: rgb(1.00, 0.45, 0.42), bottom: rgb(0.93, 0.20, 0.22)),
        Swatch(key: "orange", name: "Orange", top: rgb(1.00, 0.68, 0.32), bottom: rgb(0.98, 0.45, 0.08)),
        Swatch(key: "yellow", name: "Yellow", top: rgb(1.00, 0.86, 0.34), bottom: rgb(0.96, 0.66, 0.02)),
        Swatch(key: "green", name: "Green", top: rgb(0.45, 0.89, 0.50), bottom: rgb(0.16, 0.70, 0.31)),
        Swatch(key: "mint", name: "Mint", top: rgb(0.42, 0.91, 0.82), bottom: rgb(0.00, 0.69, 0.62)),
        Swatch(key: "teal", name: "Teal", top: rgb(0.38, 0.82, 0.92), bottom: rgb(0.04, 0.56, 0.72)),
        Swatch(key: "blue", name: "Blue", top: rgb(0.38, 0.69, 1.00), bottom: rgb(0.04, 0.42, 0.96)),
        Swatch(key: "indigo", name: "Indigo", top: rgb(0.53, 0.52, 1.00), bottom: rgb(0.31, 0.26, 0.87)),
        Swatch(key: "purple", name: "Purple", top: rgb(0.80, 0.53, 1.00), bottom: rgb(0.56, 0.26, 0.88)),
        Swatch(key: "pink", name: "Pink", top: rgb(1.00, 0.52, 0.69), bottom: rgb(0.93, 0.20, 0.46)),
        Swatch(key: "brown", name: "Brown", top: rgb(0.80, 0.65, 0.49), bottom: rgb(0.57, 0.42, 0.28)),
        Swatch(key: "graphite", name: "Graphite", top: rgb(0.52, 0.54, 0.58), bottom: rgb(0.24, 0.26, 0.30)),
    ]

    static func swatch(_ key: String) -> Swatch {
        swatches.first { $0.key == key } ?? swatches[6]
    }
}

// MARK: - Symbols

enum Symbols {
    static let services = [
        "globe", "server.rack", "cpu.fill", "memorychip.fill", "externaldrive.fill", "internaldrive.fill",
        "archivebox.fill", "folder.fill", "network", "wifi", "antenna.radiowaves.left.and.right", "lock.shield.fill",
        "checkmark.shield.fill", "flame.fill", "bolt.fill", "bolt.batteryblock.fill", "chart.xyaxis.line", "chart.bar.fill",
        "gauge.with.dots.needle.67percent", "waveform.path.ecg", "bell.badge.fill", "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.2.fill", "shippingbox.fill", "cube.fill", "square.stack.3d.up.fill",
        "cloud.fill", "house.fill", "desktopcomputer", "laptopcomputer", "display", "printer.fill",
        "video.fill", "camera.fill", "play.rectangle.fill", "music.note", "clock.fill", "calendar",
        "person.2.fill", "envelope.fill", "key.fill", "cylinder.split.1x2.fill", "doc.text.fill", "book.fill",
        "lightbulb.fill", "thermometer.medium", "sparkles", "leaf.fill", "pawprint.fill", "ant.fill",
    ]

    static let groups = [
        "folder.fill", "server.rack", "house.fill", "building.2.fill", "cloud.fill", "network",
        "chart.bar.fill", "terminal.fill", "externaldrive.fill", "shippingbox.fill", "lock.shield.fill", "wrench.and.screwdriver.fill",
        "flame.fill", "bolt.fill", "globe", "briefcase.fill", "star.fill", "heart.fill",
        "flag.fill", "tag.fill", "leaf.fill", "sparkles", "person.2.fill", "gamecontroller.fill",
    ]
}

enum Appearance {
    /// Keyword → (symbol, color). Order matters: the first match wins.
    private static let rules: [([String], String, String)] = [
        (["shell", "console", "bash", "zsh"], "terminal.fill", "graphite"),
        (["proxmox", "pve", "esxi", "vmware", "hyperv", "hyp", "xcp"], "server.rack", "orange"),
        (["opnsense", "pfsense", "firewall", "sophos", "fortigate"], "flame.fill", "red"),
        (["unifi", "wifi", "wlan", "omada", "ap"], "wifi", "blue"),
        (["grafana", "dashboard", "kibana"], "chart.xyaxis.line", "orange"),
        (["prometheus", "alert", "alertmanager", "zabbix", "uptime", "monitor", "nagios", "checkmk"], "waveform.path.ecg", "red"),
        (["pi-hole", "pihole", "hole", "adguard", "dns", "bind", "unbound"], "checkmark.shield.fill", "red"),
        (["semaphore", "ansible", "awx", "jenkins", "rundeck", "ci"], "gearshape.2.fill", "purple"),
        (["npm", "nginx", "proxy", "traefik", "caddy", "haproxy"], "arrow.triangle.branch", "green"),
        (["kimai", "time", "timer", "clock"], "clock.fill", "teal"),
        (["filebrowser", "file", "files", "nextcloud", "seafile", "owncloud"], "folder.fill", "blue"),
        (["claude", "ai", "llm", "gpt", "ollama", "openwebui"], "sparkles", "orange"),
        (["ups", "nut", "power", "pdu", "battery", "apc"], "bolt.batteryblock.fill", "yellow"),
        (["nas", "dsm", "synology", "truenas", "unraid", "qnap", "storage"], "externaldrive.fill", "teal"),
        (["ssd", "disk", "nvme", "san", "iscsi", "ceph"], "internaldrive.fill", "mint"),
        (["raspi", "raspberry", "rpi", "pi"], "cpu.fill", "pink"),
        (["docker", "portainer", "container", "k8s", "kube", "kubernetes", "rancher", "argo"], "shippingbox.fill", "blue"),
        (["home", "hass", "homeassistant", "openhab", "iobroker"], "house.fill", "teal"),
        (["git", "gitea", "gitlab", "forgejo", "code", "github"], "chevron.left.forwardslash.chevron.right", "orange"),
        (["mail", "smtp", "imap", "mailcow", "postfix"], "envelope.fill", "blue"),
        (["camera", "nvr", "frigate", "cctv", "cam"], "video.fill", "indigo"),
        (["plex", "jellyfin", "emby", "media", "sonarr", "radarr"], "play.rectangle.fill", "purple"),
        (["db", "postgres", "mysql", "maria", "mariadb", "redis", "mongo", "sql", "pgadmin"], "cylinder.split.1x2.fill", "brown"),
        (["vault", "bitwarden", "vaultwarden", "password", "keycloak", "auth", "authentik"], "key.fill", "yellow"),
        (["printer", "cups", "print"], "printer.fill", "graphite"),
        (["vpn", "wireguard", "openvpn", "tailscale", "headscale"], "lock.shield.fill", "green"),
        (["router", "switch", "mikrotik", "network", "lan", "netbox"], "network", "teal"),
        (["wiki", "docs", "bookstack", "notes", "outline"], "book.fill", "brown"),
    ]

    private static var cache: [String: (symbol: String, color: String)] = [:]

    static func guess(for s: Service) -> (symbol: String, color: String) {
        let key = "\(s.isTerminal)|\(s.name)"
        if let hit = cache[key] { return hit }
        let words = s.name.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .flatMap { w -> [Substring] in w.contains("-") ? [w] + w.split(separator: "-") : [w] }
        let result: (symbol: String, color: String)
        if let rule = rules.first(where: { rule in words.contains { w in rule.0.contains { matches(String(w), $0) } } }) {
            result = (rule.1, rule.2)
        } else if s.isTerminal {
            result = ("terminal.fill", "graphite")
        } else {
            // Stable color derived from the name, so it doesn't change on every launch.
            let colors = Palette.swatches.map(\.key).filter { $0 != "graphite" && $0 != "brown" }
            let h = s.name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
            result = ("globe", colors[abs(h) % colors.count])
        }
        cache[key] = result
        return result
    }

    /// Short keywords only match a whole word (or one followed by digits, e.g. "dns01"),
    /// longer ones also match the start of a word ("hyp01", "nashdd").
    private static func matches(_ word: String, _ kw: String) -> Bool {
        if word == kw { return true }
        guard word.hasPrefix(kw) else { return false }
        if kw.count >= 3 { return true }
        return word.dropFirst(kw.count).allSatisfy(\.isNumber)
    }
}

// MARK: - Sidebar and view

enum SidebarItem: Hashable, RawRepresentable {
    case all, active, web, shells, group(UUID)

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "active": self = .active
        case "web": self = .web
        case "shells": self = .shells
        default:
            guard rawValue.hasPrefix("g:"), let id = UUID(uuidString: String(rawValue.dropFirst(2))) else { return nil }
            self = .group(id)
        }
    }

    var rawValue: String {
        switch self {
        case .all: "all"
        case .active: "active"
        case .web: "web"
        case .shells: "shells"
        case .group(let id): "g:" + id.uuidString
        }
    }

    var groupID: UUID? {
        if case .group(let id) = self { return id }
        return nil
    }
}

enum ViewMode: String {
    case grid, list
}
