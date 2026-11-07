// InfraLauncher – a small Mac app: start an SSH tunnel and open the service in the browser.
// Built with build.sh, no Xcode project.

import SwiftUI
import AppKit

enum Prefs {
    static let menuBarKey = "showMenuBarExtra"
    static var showMenuBar: Bool { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With the menu bar icon, the app (and its tunnels) keeps running when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Prefs.showMenuBar }

    // No orphaned ssh processes blocking ports.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Store.shared.stopAll() }
    }
}

@main
struct InfraLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared
    @StateObject private var ui = UIState.shared
    @AppStorage(Prefs.menuBarKey) private var showMenuBar = true

    var body: some Scene {
        Window("InfraLauncher", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(ui)
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Service") { ui.newService() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Group") { ui.newGroup() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Stop All Tunnels") { store.stopAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(store.activeCount == 0)
                Divider()
                Button("Restore Example Services…") { ui.confirmRestore = true }
            }
            CommandGroup(before: .toolbar) {
                Button("as Icons") { ui.viewMode = .grid }
                    .keyboardShortcut("1", modifiers: .command)
                Button("as List") { ui.viewMode = .list }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
            }
            CommandMenu("Go") {
                Button("All Services") { ui.selection = .all }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Active") { ui.selection = .active }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Web") { ui.selection = .web }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Shells") { ui.selection = .shells }.keyboardShortcut("4", modifiers: [.command, .option])
                if !store.groups.isEmpty {
                    Divider()
                    ForEach(store.groups) { g in
                        Button(g.name) { ui.selection = .group(g.id) }
                    }
                }
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarPanel()
                .environmentObject(store)
                .environmentObject(ui)
        } label: {
            Image(systemName: store.activeCount > 0
                  ? "point.3.filled.connected.trianglepath.dotted"
                  : "point.3.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.menuBarKey) private var showMenuBar = true
    @AppStorage(TerminalApp.prefsKey) private var terminal = TerminalApp.terminal.rawValue

    var body: some View {
        Form {
            Section {
                Picker(selection: $terminal) {
                    ForEach(TerminalApp.installed) { app in
                        HStack {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text(app.name)
                        }
                        .tag(app.rawValue)
                    }
                } label: {
                    Text("Open shells in")
                    Text("Services without a URL open a new window in this app.")
                }
            }
            Section {
                Toggle(isOn: $showMenuBar) {
                    Text("Show in menu bar")
                    Text("Start tunnels and open services from the menu bar. Closing the window keeps InfraLauncher and its tunnels running; quitting stops them.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}

// MARK: - Menu bar

struct MenuBarPanel: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    @Environment(\.openWindow) private var openWindow

    private var sections: [(id: String, group: ServiceGroup?, services: [Service])] {
        var out = store.groups.map { g in (g.id.uuidString, Optional(g), store.services(in: g.id)) }
        let known = Set(store.groups.map(\.id))
        out.append(("ungrouped", nil, store.services.filter { $0.groupID.map { !known.contains($0) } ?? true }))
        return out.filter { !$0.2.isEmpty }
    }

    var body: some View {
        let sections = sections
        let rows = store.services.count
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("InfraLauncher").font(.system(size: 13, weight: .semibold))
                    Text(store.activeCount == 0 ? "No active tunnels" : "\(store.activeCount) active")
                        .font(.system(size: 11))
                        .foregroundStyle(store.activeCount == 0 ? Color.secondary : Color.green)
                        .contentTransition(.numericText())
                }
                Spacer()
                if store.activeCount > 0 {
                    Button("Stop All") { store.stopAll() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sections, id: \.id) { s in
                        if sections.count > 1 || s.group != nil {
                            Text(s.group?.name ?? "No Group")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        ForEach(s.services) { svc in
                            MenuBarRow(service: svc)
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(rows) * 40 + CGFloat(sections.count) * 26 + 12, 460))

            Divider()

            HStack {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Text("Open InfraLauncher") }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: { Text("Quit") }
                .buttonStyle(.borderless)
                .help("Quit and stop all tunnels")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 340)
    }
}

private struct MenuBarRow: View {
    @EnvironmentObject private var store: Store
    let service: Service
    @State private var hover = false

    var body: some View {
        let state = store.state(service.id)
        HStack(spacing: 10) {
            ServiceIcon(service: service, size: 26, state: state, ring: .windowBackground)
            VStack(alignment: .leading, spacing: 0) {
                Text(service.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                StatusText(service: service, style: .tile)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let ph = service.placeholder {
                TextField(ph, text: Binding(
                    get: { store.inputs[service.id] ?? "" },
                    set: { store.inputs[service.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .controlSize(.small)
                    .frame(width: 96)
                    .onSubmit { store.open(service) }
            }
            if !service.isTerminal {
                Toggle("", isOn: Binding(
                    get: { state.isActive },
                    set: { $0 ? store.start(service) : store.stop(service.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            OpenPill(service: service, compact: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
