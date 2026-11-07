// Building blocks shared by the list, grid, menu bar and editor.

import SwiftUI
import AppKit

extension Color {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
}

// MARK: - Service icon

/// App-icon-style tile: squircle with a gradient, a glossy edge and a white symbol.
/// State shows as a ring running around it (connecting) or a badge (running, failed).
struct ServiceIcon: View {
    let symbol: String
    let color: String
    var size: CGFloat
    /// nil = don't show a state (terminal entries, editor).
    var state: TunnelState? = nil
    /// Color behind the badge, so it looks cleanly cut out.
    var ring: Color = .windowBackground

    init(symbol: String, color: String, size: CGFloat, state: TunnelState? = nil, ring: Color = .windowBackground) {
        self.symbol = symbol
        self.color = color
        self.size = size
        self.state = state
        self.ring = ring
    }

    init(service: Service, size: CGFloat, state: TunnelState? = nil, ring: Color = .windowBackground) {
        self.init(symbol: service.resolvedSymbol, color: service.resolvedColor, size: size,
                  state: service.isTerminal ? nil : state, ring: ring)
    }

    private var radius: CGFloat { size * 0.2237 }

    var body: some View {
        let swatch = Palette.swatch(color)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(swatch.gradient)
            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)],
                                      startPoint: .top, endPoint: .center))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.06)],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: max(0.5, size / 80))
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: size / 48, y: size / 72)
        }
        .frame(width: size, height: size)
        .shadow(color: swatch.bottom.opacity(0.32), radius: size / 12, y: size / 22)
        .shadow(color: state == .up ? .green.opacity(0.55) : .clear, radius: size / 7)
        .overlay {
            if state == .connecting { ConnectingRing(size: size, radius: radius) }
        }
        .overlay(alignment: .bottomTrailing) { badge }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state)
    }

    @ViewBuilder private var badge: some View {
        let b = max(9, size * 0.3)
        let border = max(1.5, b * 0.16)
        switch state {
        case .up:
            Circle().fill(ring).frame(width: b + border * 2, height: b + border * 2)
                .overlay(Circle().fill(LinearGradient(colors: [Color(red: 0.42, green: 0.92, blue: 0.47), Color(red: 0.13, green: 0.72, blue: 0.29)], startPoint: .top, endPoint: .bottom)).padding(border))
                .overlay {
                    if size >= 44 {
                        Image(systemName: "checkmark").font(.system(size: b * 0.5, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .offset(x: b * 0.3, y: b * 0.3)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Circle().fill(ring).frame(width: b + border * 2, height: b + border * 2)
                .overlay(Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.40), Color(red: 0.88, green: 0.16, blue: 0.20)], startPoint: .top, endPoint: .bottom)).padding(border))
                .overlay {
                    if size >= 28 {
                        Image(systemName: "exclamationmark").font(.system(size: b * 0.55, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .offset(x: b * 0.3, y: b * 0.3)
                .transition(.scale.combined(with: .opacity))
        default:
            EmptyView()
        }
    }
}

/// Streak of light running around the icon while the tunnel is being set up.
private struct ConnectingRing: View {
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        let gap = max(2.5, size / 18)
        let line = max(2, size / 22)
        let shape = RoundedRectangle(cornerRadius: radius + gap, style: .continuous)
        TimelineView(.animation) { ctx in
            let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
            let len = 0.3
            let style = StrokeStyle(lineWidth: line, lineCap: .round)
            let grad = AngularGradient(colors: [.orange, .yellow, .orange], center: .center)
            ZStack {
                shape.stroke(Color.orange.opacity(0.18), lineWidth: line)
                shape.trim(from: p, to: min(p + len, 1)).stroke(grad, style: style)
                shape.trim(from: 0, to: max(0, p + len - 1)).stroke(grad, style: style)
            }
        }
        .frame(width: size + gap * 2, height: size + gap * 2)
        .transition(.opacity)
    }
}

// MARK: - Groupn-Plakette

/// Round, colored symbol like Reminders lists.
struct GroupBadge: View {
    let symbol: String
    let color: String
    var size: CGFloat

    init(group: ServiceGroup?, size: CGFloat) {
        symbol = group?.symbol ?? "tray.fill"
        color = group?.color ?? "graphite"
        self.size = size
    }

    init(symbol: String, color: String, size: CGFloat) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    var body: some View {
        let swatch = Palette.swatch(color)
        ZStack {
            Circle().fill(swatch.gradient)
            Circle().fill(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center))
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: swatch.bottom.opacity(size > 40 ? 0.35 : 0), radius: size / 10, y: size / 20)
    }
}

// MARK: - Open button

/// Capsule in the style of the App Store's "OPEN". Shows a spinner while the tunnel
/// is still being set up and the browser opens automatically afterwards.
struct OpenPill: View {
    @EnvironmentObject private var store: Store
    let service: Service
    var compact = false
    @State private var hover = false

    var body: some View {
        let waiting = store.pendingOpen.contains(service.id)
        Button { store.open(service) } label: {
            ZStack {
                Text("OPEN").opacity(waiting ? 0 : 1)
                if waiting { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: compact ? 10.5 : 12, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: compact ? 40 : 50)
            .padding(.vertical, compact ? 3 : 4.5)
            .padding(.horizontal, compact ? 8 : 11)
            .background(Capsule().fill(Color.primary.opacity(hover ? 0.13 : 0.075)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(service.isTerminal ? "Open in \(TerminalApp.current.name)" : "Connect and open in browser")
    }
}

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Status line

struct StatusText: View {
    enum Style { case row, tile }

    @EnvironmentObject private var store: Store
    let service: Service
    var style: Style = .row

    var body: some View {
        switch store.state(service.id) {
        case .failed(let msg):
            Text(msg).foregroundStyle(.red)
        case .connecting:
            Text(store.pendingOpen.contains(service.id) && style == .row ? "Connecting, then opening…" : "Connecting…")
                .foregroundStyle(.orange)
        case .up:
            if let note = store.notes[service.id] {
                Text(note).foregroundStyle(.orange)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    let up = Text(connected(ctx.date)).foregroundColor(.green)
                    if style == .row {
                        up + Text("   " + service.summary).foregroundColor(.secondary)
                    } else {
                        up
                    }
                }
            }
        case .idle:
            if style == .row {
                Text(service.summary).foregroundStyle(.secondary)
            } else {
                Text(service.shortSummary).foregroundStyle(.tertiary)
            }
        }
    }

    private func connected(_ now: Date) -> String {
        guard let since = store.since[service.id] else { return "Connected" }
        let m = Int(now.timeIntervalSince(since)) / 60
        let t: String
        switch m {
        case ..<1: return "Connected"
        case ..<60: t = "\(m)m"
        case ..<1440: t = "\(m / 60)h \(m % 60)m"
        default: t = "\(m / 1440)d \(m / 60 % 24)h"
        }
        return "Connected · " + t
    }
}

// MARK: - Service context menu

struct ServiceMenu: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    let service: Service

    var body: some View {
        Button(service.isTerminal ? "Open in \(TerminalApp.current.name)" : "Open in Browser") { store.open(service) }
        if !service.isTerminal {
            Button(store.state(service.id).isActive ? "Stop Tunnel" : "Start Tunnel") { store.toggle(service) }
        }
        Divider()
        Button("Edit…") { ui.editingService = service }
        Button("Duplicate") { store.duplicate(service.id) }
        Menu("Move to Group") {
            Button("No Group") { withAnimation(.snappy) { store.assign(service.id, to: nil) } }
                .disabled(service.groupID == nil)
            if !store.groups.isEmpty { Divider() }
            ForEach(store.groups) { g in
                Button { withAnimation(.snappy) { store.assign(service.id, to: g.id) } } label: {
                    Label(g.name, systemImage: g.symbol)
                }
                .disabled(service.groupID == g.id)
            }
            Divider()
            Button("New Group…") { ui.newGroup(moving: service.id) }
        }
        Divider()
        Button("Copy Command") { copy(service.command) }
        if !service.urls.isEmpty {
            Button(service.urls.count == 1 ? "Copy URL" : "Copy URLs") { copy(service.urls.joined(separator: "\n")) }
        }
        Divider()
        Button("Delete…", role: .destructive) { ui.pendingDelete = service }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Placeholder prompt

/// Small popover for entries with <ip> or similar, with recently used values.
struct InputPopover: View {
    @EnvironmentObject private var store: Store
    let service: Service
    let placeholder: String
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool

    private var value: Binding<String> {
        Binding(get: { store.inputs[service.id] ?? "" }, set: { store.inputs[service.id] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ServiceIcon(service: service, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name).font(.headline)
                    Text("Enter \(placeholder)").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .focused($focused)
                .onSubmit(go)
            if let recent = store.recents[service.id], !recent.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(recent, id: \.self) { r in
                        Button { value.wrappedValue = r; go() } label: {
                            Text(r)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(service.isTerminal ? "Open Shell" : "Connect", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 290)
        .onAppear { focused = true }
    }

    private func go() {
        guard !value.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isPresented = false
        store.open(service)
    }
}

// MARK: - Color and symbol pickers

struct SwatchPicker: View {
    @Binding var selection: String?
    /// With "Automatic" as the first choice.
    var allowsAutomatic = false
    var automaticColor: String = "blue"

    var body: some View {
        HStack(spacing: 7) {
            if allowsAutomatic {
                dot(selected: selection == nil, help: "Automatic") {
                    Circle().fill(AngularGradient(colors: Palette.swatches.dropLast(2).map(\.tint) + [Palette.swatches[0].tint], center: .center))
                        .overlay(Image(systemName: "wand.and.stars").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                } action: { selection = nil }
            }
            ForEach(Palette.swatches) { s in
                dot(selected: selection == s.key, help: s.name) {
                    Circle().fill(s.gradient)
                } action: { selection = s.key }
            }
        }
    }

    private func dot<C: View>(selected: Bool, help: String, @ViewBuilder content: () -> C, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            content()
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.35 : 0), lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .help(help)
    }
}

struct SymbolPicker: View {
    @Binding var selection: String?
    let symbols: [String]
    let color: String
    var allowsAutomatic = false
    var columns = 8

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: columns), spacing: 6) {
            if allowsAutomatic {
                cell("wand.and.stars", selected: selection == nil, help: "Automatic") { selection = nil }
            }
            ForEach(symbols, id: \.self) { s in
                cell(s, selected: selection == s, help: s) { selection = s }
            }
        }
    }

    private func cell(_ symbol: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        SymbolCell(symbol: symbol, selected: selected, color: color, action: { withAnimation(.snappy) { action() } })
            .help(help)
    }
}

private struct SymbolCell: View {
    let symbol: String
    let selected: Bool
    let color: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(selected ? AnyShapeStyle(Palette.swatch(color).gradient)
                                  : AnyShapeStyle(Color.primary.opacity(hover ? 0.09 : 0.045)))
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .onHover { hover = $0 }
    }
}

// MARK: - Flow layout

/// Lays out elements side by side and wraps when needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: maxX, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: - Drag to reorder

/// Reorders live as soon as a dragged service moves over another element.
struct ReorderDropDelegate: DropDelegate {
    let target: UUID
    let store: Store
    let drag: DragState
    let adoptGroup: Bool

    func dropEntered(info: DropInfo) {
        guard let id = drag.id, id != target else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            store.move(id, to: target, adoptGroup: adoptGroup)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func validateDrop(info: DropInfo) -> Bool { drag.id != nil }

    func performDrop(info: DropInfo) -> Bool {
        drag.end()
        return true
    }
}

extension View {
    /// Makes an element draggable and reorderable.
    func reorderable(_ service: Service, store: Store, drag: DragState, adoptGroup: Bool, iconSize: CGFloat = 48) -> some View {
        self
            .opacity(drag.id == service.id ? 0.3 : 1)
            .onDrag {
                drag.begin(service.id)
                return NSItemProvider(object: service.id.uuidString as NSString)
            } preview: {
                ServiceIcon(service: service, size: iconSize)
                    .padding(8)
            }
            .onDrop(of: [.text], delegate: ReorderDropDelegate(target: service.id, store: store, drag: drag, adoptGroup: adoptGroup))
    }
}
