//
//  PluginsSettingsView.swift
//  MinisApp
//
//  Settings > Agent Runtime > Plugins, plus the per-plugin detail page.
//
//  This is the DSH-style surface: a list of prompt plugins with a switch, and
//  a detail page where modules are toggled individually or through a profile.
//  Nothing here touches tools or code — enabling a plugin changes the system
//  prompt on the next turn.
//

import SwiftUI
import UniformTypeIdentifiers

struct PluginsSettingsView: View {
    @ObservedObject private var store = PluginStore.shared

    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var pendingRemoval: InstalledPlugin?

    var body: some View {
        List {
            if store.plugins.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(store.plugins) { plugin in
                        NavigationLink {
                            PluginDetailView(pluginId: plugin.id)
                        } label: {
                            row(for: plugin)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingRemoval = plugin
                            } label: {
                                Label(AppLocalized("Remove"), systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text(AppLocalized("A plugin injects prompt modules into the system prompt. Enabled plugins apply from the next message — no restart needed."))
                }
            }
        }
        .navigationTitle(Text("Plugins"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Install Plugin"))
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(
            AppLocalized("Plugin Error"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            AppLocalized("Remove this plugin?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { plugin in
            Button(AppLocalized("Remove Plugin"), role: .destructive) {
                store.uninstall(plugin.id)
                pendingRemoval = nil
            }
            Button(AppLocalized("Cancel"), role: .cancel) { pendingRemoval = nil }
        } message: { plugin in
            Text(plugin.manifest.name + " · " + plugin.summary)
        }
    }

    // MARK: Rows

    private func row(for plugin: InstalledPlugin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.mint, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.manifest.name)
                        .lineLimit(1)
                    Text("v" + plugin.manifest.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(plugin.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(AppLocalized("No plugins installed"), systemImage: "puzzlepiece")
                    .font(.headline)
                Text(AppLocalized("A plugin is a folder with plugin.json and a prompts/ directory. Install one to change the agent's behavior, the way SOUL.md changes its identity."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    showImporter = true
                } label: {
                    Label(AppLocalized("Install from Files"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // The security scope is only valid while held; install copies
            // synchronously so the whole call stays inside it.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try store.install(fromDirectory: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Detail

struct PluginDetailView: View {
    let pluginId: String

    @ObservedObject private var store = PluginStore.shared
    @State private var showPreview = false

    private var plugin: InstalledPlugin? {
        store.plugins.first(where: { $0.id == pluginId })
    }

    var body: some View {
        Group {
            if let plugin {
                content(for: plugin)
            } else {
                Text(AppLocalized("This plugin is no longer installed."))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(plugin?.manifest.name ?? AppLocalized("Plugin"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(for plugin: InstalledPlugin) -> some View {
        let active = Set(plugin.activeModuleIds)

        List {
            Section {
                Toggle(isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { store.setEnabled(plugin.id, enabled: $0) }
                )) {
                    Text(AppLocalized("Enable Plugin"))
                }
                if let description = plugin.manifest.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            } footer: {
                if let author = plugin.manifest.author, !author.isEmpty {
                    Text(AppLocalized("By ") + author)
                }
            }

            if let profiles = plugin.manifest.profiles, !profiles.isEmpty {
                Section("Presets") {
                    ForEach(profiles.keys.sorted(), id: \.self) { name in
                        Button {
                            store.applyProfile(plugin.id, named: name)
                        } label: {
                            HStack {
                                Text(name)
                                Spacer()
                                if matches(profile: profiles[name] ?? [], active: active, plugin: plugin) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                ForEach(plugin.manifest.modules) { module in
                    Toggle(isOn: Binding(
                        get: { active.contains(module.id) },
                        set: { store.toggleModule(plugin.id, moduleId: module.id, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(module.name.isEmpty ? module.id : module.name)
                            Text(module.file)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!plugin.isEnabled)
                }
            } header: {
                Text("Modules")
            } footer: {
                Text(AppLocalized("Modules run in the order listed. Disabled modules are not read at all."))
            }

            Section {
                Button {
                    showPreview = true
                } label: {
                    Label(AppLocalized("Preview Injected Prompt"), systemImage: "doc.text.magnifyingglass")
                }
                .disabled(!plugin.isEnabled)
            } footer: {
                Text(AppLocalized("Prompt plugins can change the agent's judgment. Only install plugins whose prompts you have read."))
            }
        }
        .sheet(isPresented: $showPreview) {
            PluginPromptPreviewSheet(pluginId: plugin.id)
        }
    }

    /// A profile is "selected" when it expands to exactly the active set.
    private func matches(profile: [String], active: Set<String>, plugin: InstalledPlugin) -> Bool {
        if profile == ["*"] {
            return active.count == plugin.manifest.modules.count
        }
        return Set(profile) == active
    }
}

// MARK: - Preview

private struct PluginPromptPreviewSheet: View {
    let pluginId: String
    @ObservedObject private var store = PluginStore.shared
    @Environment(\.dismiss) private var dismiss

    private var fragment: String {
        // The preview shows the plugin in isolation rather than the whole
        // assembled system prompt: this is the text the author wrote, and it is
        // what a reviewer needs to read before trusting the package.
        guard let plugin = store.plugins.first(where: { $0.id == pluginId }) else { return "" }
        var pieces: [String] = []
        for module in plugin.activeModules {
            let url = plugin.directoryURL.appendingPathComponent(module.file)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                pieces.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(fragment.isEmpty ? AppLocalized("Nothing to inject: no modules are active.") : fragment)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(Text("Injected Prompt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Done")) { dismiss() }
                }
            }
        }
    }
}