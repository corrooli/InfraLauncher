// Main window: sidebar with collections and groups, grid or list on the right.

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    @StateObject private var drag = DragState()
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 320)
        } detail: {
            DetailView(query: query)
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Services")
        .environmentObject(drag)
        .sheet(item: $ui.editingService) { s in
            ServiceEditor(original: s).environmentObject(store).environmentObject(ui)
        }
        .sheet(item: $ui.editingGroup) { g in
            GroupEditor(original: g).environmentObject(store).environmentObject(ui)
        }
        .alert(
            "Delete “\(ui.pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { ui.pendingDelete != nil }, set: { if !$0 { ui.pendingDelete = nil } }),
            presenting: ui.pendingDelete
        ) { s in
            Button("Delete", role: .destructive) { withAnimation(.snappy) { store.delete(s.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The service is removed from your list. A running tunnel is stopped.")
        }
        .alert("Restore the example services?", isPresented: $ui.confirmRestore) {
            Button("Replace My List", role: .destructive) { store.restoreDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All your services and groups are replaced by the examples. This can’t be undone.")
        }
        .onChange(of: store.groups) { _, groups in
            if case .group(let id) = ui.selection, !groups.contains(where: { $0.id == id }) { ui.selection = .all }
        }
    }

    private var title: String {
        switch ui.selection {
        case .all: "All Services"
        case .active: "Active"
        case .web: "Web"
        case .shells: "Shells"
        case .group(let id): store.group(id)?.name ?? "InfraLauncher"
        }
    }

    private var subtitle: String {
        let list = store.services(for: ui.selection)
        let active = list.filter { store.state($0.id).isActive }.count
        let n = list.count == 1 ? "1 service" : "\(list.count) services"
        return active == 0 ? n : "\(n) · \(active) active"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $ui.viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid).help("Icons (⌘1)")
                Image(systemName: "list.bullet").tag(ViewMode.list).help("List (⌘2)")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.stopAll() } label: { Label("Stop All", systemImage: "stop.circle") }
                .help("Stop all tunnels (⌘.)")
                .disabled(store.activeCount == 0)
            Button { ui.newService() } label: { Label("New Service", systemImage: "plus") }
                .help("New service (⌘N)")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState

    var body: some View {
        List(selection: Binding(
            get: { ui.selection.groupID.map { SidebarItem.group($0) } },
            set: { if let v = $0 { ui.selection = v } }
        )) {
            Section {
                SmartTiles()
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
                    .selectionDisabled()
            }
            Section("Groups") {
                ForEach(store.groups) { g in
                    GroupRow(group: g).tag(SidebarItem.group(g.id))
                }
                .onMove { store.moveGroups(from: $0, to: $1) }
                if store.groups.isEmpty {
                    Text("Group services by place, purpose or customer. Drag services onto a group to move them.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case .group(let id) = ui.selection { withAnimation { store.deleteGroup(id) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { ui.newGroup() } label: {
                    Label("New Group", systemImage: "plus.circle")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// Four collections as tiles, like in Reminders.
private struct SmartTiles: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                SmartTile(item: .all, title: "All", symbol: "square.grid.2x2.fill", color: "blue")
                SmartTile(item: .active, title: "Active", symbol: "bolt.fill", color: "green")
            }
            GridRow {
                SmartTile(item: .web, title: "Web", symbol: "globe", color: "indigo")
                SmartTile(item: .shells, title: "Shells", symbol: "terminal.fill", color: "graphite")
            }
        }
    }
}

private struct SmartTile: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    let item: SidebarItem
    let title: String
    let symbol: String
    let color: String

    var body: some View {
        let selected = ui.selection == item
        let swatch = Palette.swatch(color)
        Button { ui.selection = item } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle().fill(selected ? AnyShapeStyle(.white) : AnyShapeStyle(swatch.gradient))
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(selected ? swatch.tint : .white)
                    }
                    .frame(width: 26, height: 26)
                    Spacer()
                    Text("\(store.services(for: item).count)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selected ? .white : .primary)
                        .contentTransition(.numericText())
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? .white : .secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AnyShapeStyle(swatch.gradient) : AnyShapeStyle(Color.primary.opacity(0.065)))
                    .shadow(color: selected ? swatch.bottom.opacity(0.35) : .clear, radius: 4, y: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .animation(.snappy(duration: 0.2), value: selected)
        .animation(.snappy, value: store.services(for: item).count)
    }
}

private struct GroupRow: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var drag: DragState
    let group: ServiceGroup
    @State private var targeted = false

    var body: some View {
        let list = store.services(in: group.id)
        let active = list.contains { store.state($0.id).isActive }
        Label {
            HStack(spacing: 6) {
                Text(group.name)
                if active {
                    Circle().fill(.green).frame(width: 6, height: 6)
                        .shadow(color: .green.opacity(0.7), radius: 2)
                        .help("Tunnels running")
                }
            }
        } icon: {
            GroupBadge(group: group, size: 20)
        }
        .badge(list.count)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-4)
                .opacity(targeted ? 1 : 0)
        )
        .onDrop(of: [.text], isTargeted: $targeted) { _ in
            guard let id = drag.id else { return false }
            withAnimation(.snappy) { store.assign(id, to: group.id) }
            drag.end()
            return true
        }
        .contextMenu {
            Button("Edit Group…") { ui.editingGroup = group }
            Divider()
            Button("Start All Tunnels") { store.startAll(list) }
            Button("Stop All Tunnels") { store.stopAll(list) }.disabled(!active)
            Divider()
            Button("Delete Group", role: .destructive) { withAnimation { store.deleteGroup(group.id) } }
        }
    }
}

// MARK: - Content

private struct ServiceSection: Identifiable {
    let id: String
    let group: ServiceGroup?
    let showsHeader: Bool
    let services: [Service]
}

struct DetailView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var drag: DragState
    let query: String

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var sections: [ServiceSection] {
        let visible = store.services(for: ui.selection).filter { $0.matches(query) || (store.group($0.groupID)?.name.localizedCaseInsensitiveContains(query) ?? false) }
        guard ui.selection == .all, !store.groups.isEmpty else {
            return [ServiceSection(id: ui.selection.rawValue, group: store.group(ui.selection.groupID), showsHeader: false, services: visible)]
        }
        var out = store.groups.map { g in
            ServiceSection(id: g.id.uuidString, group: g, showsHeader: true, services: visible.filter { $0.groupID == g.id })
        }
        let known = Set(store.groups.map(\.id))
        let loose = visible.filter { $0.groupID.map { !known.contains($0) } ?? true }
        if !loose.isEmpty { out.append(ServiceSection(id: "ungrouped", group: nil, showsHeader: true, services: loose)) }
        return searching ? out.filter { !$0.services.isEmpty } : out
    }

    /// In collections like "Active", a service keeps its group when reordered.
    private var adoptGroup: Bool {
        if case .group = ui.selection { return true }
        return ui.selection == .all
    }

    var body: some View {
        let sections = sections
        Group {
            if sections.allSatisfy({ $0.services.isEmpty }) && !(ui.selection == .all && !store.groups.isEmpty && !searching) {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(sections) { section in
                            SectionView(section: section, adoptGroup: adoptGroup)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                    .frame(maxWidth: ui.viewMode == .list ? 860 : .infinity)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.windowBackground)
        .animation(.snappy(duration: 0.28), value: ui.viewMode)
    }

    @ViewBuilder private var empty: some View {
        if searching {
            ContentUnavailableView.search(text: query)
        } else {
            switch ui.selection {
            case .active:
                ContentUnavailableView("No Active Tunnels", systemImage: "bolt.slash.fill",
                                       description: Text("Flip a switch or click Open, and running tunnels show up here."))
            case .shells:
                ContentUnavailableView("No Shells", systemImage: "terminal.fill",
                                       description: Text("Services without a URL open in Terminal and are listed here."))
            case .group(let id):
                VStack(spacing: 0) {
                    ContentUnavailableView {
                        Label { Text("\(store.group(id)?.name ?? "Group") is empty") } icon: {
                            GroupBadge(group: store.group(id), size: 56)
                        }
                    } description: {
                        Text("Drag services onto the group in the sidebar, or create a new one here.")
                    } actions: {
                        Button("New Service") { ui.newService() }
                    }
                }
            default:
                ContentUnavailableView {
                    Label("No Services", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Add a tunnel or a shell to get started.")
                } actions: {
                    Button("New Service") { ui.newService() }
                }
            }
        }
    }
}

private struct SectionView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var drag: DragState
    let section: ServiceSection
    let adoptGroup: Bool

    private var key: String { section.group?.id.uuidString ?? "ungrouped" }
    private var collapsed: Bool { section.showsHeader && store.collapsed.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if section.showsHeader {
                SectionHeader(group: section.group, services: section.services, collapsed: collapsed) {
                    withAnimation(.snappy(duration: 0.3)) { store.toggleCollapsed(key) }
                }
            }
            if !collapsed {
                Group {
                    if section.services.isEmpty {
                        EmptyDropZone(group: section.group)
                    } else if ui.viewMode == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: 6, alignment: .top)], alignment: .leading, spacing: 8) {
                            ForEach(section.services) { s in
                                ServiceTile(service: s)
                                    .reorderable(s, store: store, drag: drag, adoptGroup: adoptGroup, iconSize: 64)
                            }
                        }
                    } else {
                        ListCard(services: section.services, adoptGroup: adoptGroup)
                    }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            }
        }
    }
}

private struct SectionHeader: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var drag: DragState
    let group: ServiceGroup?
    let services: [Service]
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        let active = services.filter { store.state($0.id).isActive }.count
        HStack(spacing: 9) {
            GroupBadge(group: group, size: 22)
            Text(group?.name ?? "No Group")
                .font(.system(size: 15, weight: .semibold))
            Text("\(services.count)")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            if active > 0 {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("\(active) active")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(Color.green.opacity(0.12)))
                .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            if let group {
                Menu {
                    Button("Start All Tunnels") { store.startAll(services) }
                    Button("Stop All Tunnels") { store.stopAll(services) }.disabled(active == 0)
                    Divider()
                    Button("Edit Group…") { ui.editingGroup = group }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .opacity(hover ? 1 : 0)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(targeted ? 0.12 : 0))
        )
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
        .onDrop(of: [.text], isTargeted: $targeted) { _ in
            guard let id = drag.id else { return false }
            withAnimation(.snappy) { store.assign(id, to: group?.id) }
            drag.end()
            return true
        }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.snappy, value: active)
    }
}

private struct EmptyDropZone: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var drag: DragState
    let group: ServiceGroup?
    @State private var targeted = false

    var body: some View {
        Text(drag.id == nil ? "No services yet" : "Drop here")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.primary.opacity(0.12))
            )
            .onDrop(of: [.text], isTargeted: $targeted) { _ in
                guard let id = drag.id else { return false }
                withAnimation(.snappy) { store.assign(id, to: group?.id) }
                drag.end()
                return true
            }
    }
}

// MARK: - Grid

struct ServiceTile: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    let service: Service
    @State private var hover = false
    @State private var asking = false

    var body: some View {
        let state = store.state(service.id)
        VStack(spacing: 9) {
            ServiceIcon(service: service, size: 64, state: state)
                .scaleEffect(hover ? 1.06 : 1)
                .offset(y: hover ? -1 : 0)
            VStack(spacing: 2) {
                Text(service.name)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                StatusText(service: service, style: .tile)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.05 : 0))
        )
        .overlay(alignment: .topTrailing) {
            if !service.isTerminal {
                PowerButton(service: service)
                    .padding(6)
                    .opacity(hover ? 1 : 0)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { activate() }
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hover)
        .popover(isPresented: $asking, arrowEdge: .bottom) {
            if let ph = service.placeholder {
                InputPopover(service: service, placeholder: ph, isPresented: $asking)
                    .environmentObject(store)
            }
        }
        .contextMenu { ServiceMenu(service: service) }
        .help(help(state))
    }

    private func activate() {
        if service.placeholder != nil { asking = true } else { store.open(service) }
    }

    private func help(_ state: TunnelState) -> String {
        if case .failed(let m) = state { return m }
        return service.isTerminal ? "Click to open a shell" : "Click to connect and open \(service.urls.joined(separator: ", "))"
    }
}

/// Small power button on a tile to toggle just the tunnel.
private struct PowerButton: View {
    @EnvironmentObject private var store: Store
    let service: Service
    @State private var hover = false

    var body: some View {
        let on = store.state(service.id).isActive
        Button { store.toggle(service) } label: {
            Image(systemName: "power")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(on ? .white : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(on ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(.regularMaterial))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                )
                .overlay(Circle().strokeBorder(Color.primary.opacity(hover ? 0.2 : 0.08), lineWidth: 0.5))
        }
        .buttonStyle(PressableStyle(scale: 0.85))
        .onHover { hover = $0 }
        .help(on ? "Stop tunnel" : "Start tunnel without opening")
    }
}

// MARK: - List

private struct ListCard: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var drag: DragState
    let services: [Service]
    let adoptGroup: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(services.enumerated()), id: \.element.id) { i, s in
                ServiceRow(service: s)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5).padding(.leading, 58) }
                    }
                    .reorderable(s, store: store, drag: drag, adoptGroup: adoptGroup, iconSize: 40)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ServiceRow: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    let service: Service
    @State private var hover = false

    var body: some View {
        let state = store.state(service.id)
        HStack(spacing: 12) {
            ServiceIcon(service: service, size: 32, state: state, ring: .cardBackground)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                StatusText(service: service, style: .row)
                    .font(.system(size: 11).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(state.failedMessage ?? service.command)

            Spacer(minLength: 10)

            Button { ui.editingService = service } label: {
                Image(systemName: "info.circle").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Edit")
            .opacity(hover ? 1 : 0)

            if let ph = service.placeholder {
                PlaceholderField(service: service, placeholder: ph)
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

            OpenPill(service: service)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(hover ? 0.03 : 0))
        .onHover { hover = $0 }
        .contextMenu { ServiceMenu(service: service) }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private struct PlaceholderField: View {
    @EnvironmentObject private var store: Store
    let service: Service
    let placeholder: String

    var body: some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: Binding(
                get: { store.inputs[service.id] ?? "" },
                set: { store.inputs[service.id] = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 130)
                .onSubmit { store.open(service) }
            if let recent = store.recents[service.id], !recent.isEmpty {
                Menu {
                    ForEach(recent, id: \.self) { r in
                        Button(r) { store.inputs[service.id] = r }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Recent values")
            }
        }
    }
}

extension TunnelState {
    var failedMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}
