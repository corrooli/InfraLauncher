// Editing services and groups.

import SwiftUI
import AppKit

struct ServiceEditor: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Service
    @State private var urlText: String
    @State private var styling = false
    @State private var mode: Mode
    @State private var spec: SimpleSpec
    /// false = the command doesn't fit simple mode.
    @State private var fitsSimple: Bool
    @FocusState private var nameFocused: Bool

    enum Mode: String { case simple, raw }

    init(original: Service) {
        _draft = State(initialValue: original)
        _urlText = State(initialValue: original.urls.joined(separator: "\n"))
        let isBlank = original.name.isEmpty && original.command.trimmingCharacters(in: .whitespaces) == "ssh -N -L"
        let parsed = SimpleSpec.parse(command: original.command, urls: original.urls)
        _spec = State(initialValue: parsed ?? SimpleSpec())
        _fitsSimple = State(initialValue: parsed != nil || isBlank)
        _mode = State(initialValue: parsed != nil || isBlank ? .simple : .raw)
    }

    private var takenPorts: Set<Int> {
        Set(store.services.filter { $0.id != draft.id }.flatMap(\.localPorts))
    }

    private func applySpec() {
        let built = spec.build(taken: takenPorts)
        draft.command = built.command
        urlText = built.urls.joined(separator: "\n")
    }

    private var isNew: Bool { !store.services.contains { $0.id == draft.id } }

    private var urls: [String] {
        urlText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Draft with the URLs as currently typed, for the preview and symbol choice.
    private var preview: Service {
        var p = draft
        p.urls = urls
        return p
    }

    private var conflicts: [(port: Int, name: String)] {
        draft.localPorts.compactMap { port in
            store.services.first { $0.id != draft.id && $0.localPorts.contains(port) }.map { (port, $0.name) }
        }
    }

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if mode == .simple { return fitsSimple && spec.isComplete }
        return !draft.command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)

            HStack {
                Spacer()
                Picker("", selection: $mode.animation(.snappy)) {
                    Text("Simple").tag(Mode.simple)
                    Text("Command").tag(Mode.raw)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Build the command from a few fields, or write it yourself")
                Spacer()
            }
            .padding(.bottom, 14)

            Group {
                if mode == .simple { simpleSection } else { rawSection }
            }
            .padding(.horizontal, 24)
            .transition(.opacity)

            HStack {
                if !isNew {
                    Button("Delete…", role: .destructive) {
                        let s = draft
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ui.pendingDelete = s }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Service" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .controlSize(.large)
            .padding(24)
        }
        .frame(width: 560)
        .onAppear {
            if isNew {
                nameFocused = true
                if mode == .simple && spec.jump.isEmpty {
                    spec.jump = SimpleSpec.knownJumpHosts(in: store.services).first ?? ""
                }
            }
        }
        .onChange(of: mode) { _, m in
            // Back to simple mode: re-read the command in case it was edited raw.
            guard m == .simple else { return }
            if let parsed = SimpleSpec.parse(command: draft.command, urls: urls) {
                spec = parsed
                fitsSimple = true
            } else {
                fitsSimple = draft.command.trimmingCharacters(in: .whitespaces) == "ssh -N -L"
            }
        }
    }

    @ViewBuilder private var simpleSection: some View {
        if fitsSimple {
            EditorCard("Connection", footer: simpleFooter) {
                SimpleBuilder(spec: $spec, jumpHosts: SimpleSpec.knownJumpHosts(in: store.services), takenPorts: takenPorts)
            }
            .onChange(of: spec) { _, _ in applySpec() }
        } else {
            EditorCard("Connection") {
                VStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("This command uses options Simple mode doesn’t cover.")
                        .font(.system(size: 12, weight: .medium))
                    Text("Keep editing it as a command, or start over with a fresh simple setup.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Edit Command") { withAnimation(.snappy) { mode = .raw } }
                        Button("Start Over") {
                            var fresh = SimpleSpec()
                            fresh.kind = preview.isTerminal ? .shell : .web
                            fresh.jump = SimpleSpec.knownJumpHosts(in: store.services).first ?? ""
                            spec = fresh
                            fitsSimple = true
                            applySpec()
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(18)
            }
        }
    }

    private var simpleFooter: Text {
        if let c = conflicts.first {
            return Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(.orange)
                + Text(verbatim: "  Port \(c.port) is also used by “\(c.name)”.").foregroundColor(.orange)
        }
        return Text(verbatim: draft.command).font(.system(size: 11, design: .monospaced))
    }

    private var rawSection: some View {
        VStack(spacing: 16) {
            EditorCard("Command", footer: commandFooter) {
                TextField("", text: $draft.command, prompt: Text("ssh -N -L 8080:192.168.1.50:80 jumphost"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(2...6)
                    .padding(12)
                if !draft.forwards.isEmpty {
                    Divider().padding(.leading, 12)
                    FlowLayout(spacing: 6) {
                        ForEach(Array(draft.forwards.enumerated()), id: \.offset) { _, f in
                            HStack(spacing: 4) {
                                Text(verbatim: ":\(f.port)").fontWeight(.semibold)
                                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                                Text(f.target).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            EditorCard("Open", footer: Text("One URL per line. Leave empty and the command opens in your terminal instead.")) {
                TextField("", text: $urlText, prompt: Text("http://localhost:8080"), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1...5)
                    .padding(12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Button { styling.toggle() } label: {
                ServiceIcon(service: preview, size: 68)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.regularMaterial).shadow(color: .black.opacity(0.2), radius: 2, y: 1))
                            .offset(x: 6, y: 6)
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.94))
            .help("Change icon and color")
            .popover(isPresented: $styling, arrowEdge: .bottom) {
                AppearancePopover(symbol: $draft.symbol, color: $draft.color, preview: preview)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $draft.name, prompt: Text("Service Name"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                    .focused($nameFocused)
                HStack(spacing: 8) {
                    Label(preview.isTerminal ? "Terminal" : (urls.count > 1 ? "\(urls.count) web pages" : "Web page"),
                          systemImage: preview.isTerminal ? "terminal" : "safari")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    groupMenu
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var groupMenu: some View {
        Menu {
            Button("No Group") { draft.groupID = nil }
            if !store.groups.isEmpty { Divider() }
            ForEach(store.groups) { g in
                Button { draft.groupID = g.id } label: { Label(g.name, systemImage: g.symbol) }
            }
        } label: {
            HStack(spacing: 5) {
                GroupBadge(group: store.group(draft.groupID), size: 14)
                Text(store.group(draft.groupID)?.name ?? "No Group")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group")
    }

    private var commandFooter: Text {
        if let c = conflicts.first {
            return Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(.orange)
                + Text(verbatim: "  Port \(c.port) is also used by “\(c.name)”. Both can’t run at the same time.").foregroundColor(.orange)
        }
        return Text("Write ") + Text("<name>").font(.system(size: 11, design: .monospaced)) + Text(" for a value that’s asked when you open it, e.g. ")
            + Text("root@<ip>").font(.system(size: 11, design: .monospaced))
    }

    private func save() {
        guard canSave else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.urls = urls
        withAnimation(.snappy) { store.upsert(draft) }
        dismiss()
    }
}

/// Editor section: title, rounded panel, explanation below.
private struct EditorCard<Content: View>: View {
    let title: String
    let footer: Text?
    @ViewBuilder let content: Content

    init(_ title: String, footer: Text? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
            if let footer {
                footer
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AppearancePopover: View {
    @Binding var symbol: String?
    @Binding var color: String?
    let preview: Service
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ServiceIcon(service: preview, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Icon").font(.headline)
                    Text(symbol == nil && color == nil ? "Chosen automatically from the name" : "Customized")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if symbol != nil || color != nil {
                    Button("Reset") { withAnimation(.snappy) { symbol = nil; color = nil } }
                        .controlSize(.small)
                }
            }
            SwatchPicker(selection: $color, allowsAutomatic: true)
            Divider()
            SymbolPicker(selection: $symbol, symbols: Symbols.services, color: preview.resolvedColor, allowsAutomatic: true, columns: 11)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Any SF Symbol name, e.g. tram.fill", text: $custom)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(applyCustom)
                if !custom.isEmpty {
                    Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(valid ? .green : .secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
            .onChange(of: custom) { _, _ in if valid { applyCustom() } }
        }
        .padding(16)
        .frame(width: 470)
    }

    private var valid: Bool {
        let n = custom.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil
    }

    private func applyCustom() {
        guard valid else { return }
        symbol = custom.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Group

struct GroupEditor: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ui: UIState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServiceGroup
    @FocusState private var nameFocused: Bool

    init(original: ServiceGroup) {
        _draft = State(initialValue: original)
    }

    private var isNew: Bool { !store.groups.contains { $0.id == draft.id } }
    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 18) {
            GroupBadge(symbol: draft.symbol, color: draft.color, size: 76)
                .padding(.top, 6)
                .animation(.snappy, value: draft)

            TextField("", text: $draft.name, prompt: Text("Group Name"))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Palette.swatch(draft.color).tint)
                .multilineTextAlignment(.center)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .focused($nameFocused)
                .onSubmit(save)

            SwatchPicker(selection: Binding(get: { draft.color }, set: { draft.color = $0 ?? "blue" }))

            Divider()

            SymbolPicker(selection: Binding(get: { draft.symbol }, set: { draft.symbol = $0 ?? "folder.fill" }),
                         symbols: Symbols.groups, color: draft.color, columns: 8)

            HStack {
                if !isNew {
                    Button("Delete Group", role: .destructive) {
                        store.deleteGroup(draft.id)
                        dismiss()
                    }
                    .help("Services in this group are kept")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Group" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard canSave else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        let new = isNew
        withAnimation(.snappy) {
            store.upsertGroup(draft)
            if new, let id = ui.assignToNewGroup { store.assign(id, to: draft.id) }
        }
        ui.assignToNewGroup = nil
        if new { ui.selection = .group(draft.id) }
        dismiss()
    }
}
