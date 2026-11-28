//
//  PluginStore.swift
//  MinisApp
//
//  Prompt plugins — the DSH-style extension point.
//
//  A plugin is a folder of prompt modules plus a manifest. It never ships code
//  and never registers a tool: it changes *how the agent behaves* by prepending
//  text to the system prompt, exactly like SOUL.md does for identity and like
//  SkillStore does for skill metadata.
//
//      <pluginsRoot>/<plugin-id>/
//          plugin.json          <- PluginManifest
//          prompts/core.md
//          prompts/output.md
//          ...
//
//  The user picks which modules are active; PluginStore.promptFragment()
//  concatenates them in manifest order and the agent loop injects the result
//  next to the skill and MCP fragments. Edits take effect on the next turn —
//  the files are read per request, so there is nothing to restart.
//
//  Selection state lives outside the package (plugins-state.json) so
//  reinstalling a plugin from an updated folder keeps the user's choices.
//

import Foundation

// MARK: - Manifest

/// One prompt module inside a package.
struct PluginModule: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Path relative to the plugin root, e.g. "prompts/core.md".
    var file: String
    /// Whether the module starts enabled. JSON key is `default`, which is a
    /// Swift keyword, so it is mapped explicitly.
    var isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, file
        case isDefault = "default"
    }
}

/// `plugin.json`. Unknown keys are ignored, so a newer packager can add fields
/// without breaking an older build.
struct PluginManifest: Codable, Equatable {
    var schemaVersion: Int?
    var id: String
    var name: String
    var version: String
    var description: String?
    var author: String?
    /// Higher runs later in the assembled prompt (closer to the user turn).
    var priority: Int?
    var modules: [PluginModule]
    /// Named module sets, e.g. { "base": ["core","output"], "full": ["*"] }.
    var profiles: [String: [String]]?
}

// MARK: - State

/// User-side selection, persisted in plugins-state.json. Separate from the
/// package because the package belongs to its author and this belongs to the
/// person who installed it.
struct PluginState: Codable, Equatable {
    var enabled: Bool
    /// nil means "use the manifest defaults" — that is what a fresh install
    /// writes, so a package update that adds a `default: true` module picks it
    /// up instead of staying pinned to an old snapshot.
    var activeModules: [String]?
}

/// A plugin as it exists on disk plus the user's selection.
struct InstalledPlugin: Identifiable, Equatable {
    var id: String { manifest.id }
    var manifest: PluginManifest
    var directoryURL: URL
    var state: PluginState

    var isEnabled: Bool { state.enabled }

    /// Modules selected in the UI, resolved against the manifest (defaults when
    /// the user never chose).
    var activeModuleIds: [String] {
        if let explicit = state.activeModules {
            let known = Set(manifest.modules.map(\.id))
            return explicit.filter { known.contains($0) }
        }
        return manifest.modules.filter { $0.isDefault ?? false }.map(\.id)
    }

    var activeModules: [PluginModule] {
        let active = Set(activeModuleIds)
        return manifest.modules.filter { active.contains($0.id) }
    }

    var summary: String {
        let count = activeModules.count
        let total = manifest.modules.count
        if total == 0 { return AppLocalized("No modules") }
        return "\(count)/\(total) " + AppLocalized("modules")
    }
}

// MARK: - PluginStore

@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    @Published private(set) var plugins: [InstalledPlugin] = []

    private let fm = FileManager.default
    private let manifestName = "plugin.json"
    private let stateFileName = "plugins-state.json"

    /// Per-plugin cap on injected characters. A prompt plugin that dwarfs the
    /// system prompt costs tokens on every single request, so the limit is
    /// enforced here rather than trusted to the package author.
    static let perPluginCharLimit = 32_000
    /// Cap on the whole plugin section.
    static let totalCharLimit = 64_000

    nonisolated static var pluginsRootDir: URL {
        AIChatViewModel.minisAppGroupRoot.appendingPathComponent("plugins", isDirectory: true)
    }

    private var stateFileURL: URL {
        AIChatViewModel.minisConfigRoot.appendingPathComponent(stateFileName, isDirectory: false)
    }

    private init() {
        try? fm.createDirectory(at: Self.pluginsRootDir, withIntermediateDirectories: true)
        reload()
    }

    // MARK: Loading

    func reload() {
        let root = Self.pluginsRootDir
        let states = readStates()

        let entries = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var loaded: [InstalledPlugin] = []
        for dir in entries where isDirectory(dir) {
            guard let manifest = readManifest(in: dir) else { continue }
            let state = states[manifest.id] ?? PluginState(
                enabled: false,
                activeModules: nil
            )
            loaded.append(InstalledPlugin(manifest: manifest, directoryURL: dir, state: state))
        }

        plugins = loaded.sorted {
            let lp = $0.manifest.priority ?? 0
            let rp = $1.manifest.priority ?? 0
            if lp != rp { return lp < rp }
            return $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
    }

    private func readManifest(in dir: URL) -> PluginManifest? {
        guard let data = try? PluginPackageIO.checkedFile(manifestName, in: dir, limit: 64 * 1024) else { return nil }
        do {
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            try validate(manifest)
            guard dir.lastPathComponent == manifest.id else { return nil }
            return manifest
        } catch {
            AppLogger(category: "PluginStore")
                .info("[Load] \(dir.lastPathComponent): bad manifest — \(error.localizedDescription)")
            return nil
        }
    }

    private func readStates() -> [String: PluginState] {
        guard let data = try? Data(contentsOf: stateFileURL),
              let decoded = try? JSONDecoder().decode([String: PluginState].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func writeStates(_ states: [String: PluginState]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(states) else { return }
        try? fm.createDirectory(
            at: stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: stateFileURL, options: .atomic)
    }

    private func persistState(for pluginId: String, _ state: PluginState) {
        var states = readStates()
        states[pluginId] = state
        writeStates(states)
    }

    // MARK: Mutation

    func setEnabled(_ pluginId: String, enabled: Bool) {
        guard var plugin = plugins.first(where: { $0.id == pluginId }) else { return }
        plugin.state.enabled = enabled
        persistState(for: pluginId, plugin.state)
        if let idx = plugins.firstIndex(where: { $0.id == pluginId }) {
            plugins[idx] = plugin
        }
    }

    func setModules(_ pluginId: String, active: [String]) {
        guard var plugin = plugins.first(where: { $0.id == pluginId }) else { return }
        let known = Set(plugin.manifest.modules.map(\.id))
        // Persist in manifest order so the assembled prompt is stable no matter
        // the order the user tapped the switches.
        plugin.state.activeModules = plugin.manifest.modules
            .map(\.id)
            .filter { active.contains($0) }
            .filter { known.contains($0) }
        persistState(for: pluginId, plugin.state)
        if let idx = plugins.firstIndex(where: { $0.id == pluginId }) {
            plugins[idx] = plugin
        }
    }

    func toggleModule(_ pluginId: String, moduleId: String, enabled: Bool) {
        guard let plugin = plugins.first(where: { $0.id == pluginId }) else { return }
        var active = Set(plugin.activeModuleIds)
        if enabled { active.insert(moduleId) } else { active.remove(moduleId) }
        setModules(pluginId, active: Array(active))
    }

    /// Apply a named profile. `["*"]` means every module in the package.
    func applyProfile(_ pluginId: String, named name: String) {
        guard let plugin = plugins.first(where: { $0.id == pluginId }),
              let profile = plugin.manifest.profiles?[name] else { return }
        if profile == ["*"] {
            setModules(pluginId, active: plugin.manifest.modules.map(\.id))
        } else {
            setModules(pluginId, active: profile)
        }
    }

    // MARK: Install / uninstall

    /// Install from a folder the user picked (Files, share sheet, workspace).
    /// The folder must contain plugin.json at its top level.
    @discardableResult
    func install(fromDirectory source: URL) throws -> InstalledPlugin {
        guard let data = try? PluginPackageIO.checkedFile(manifestName, in: source, limit: 64 * 1024) else {
            if fm.fileExists(atPath: source.appendingPathComponent("package.json").path) {
                throw PluginError.invalidManifest("requires_runtime: 这是 DSH/npm 代码插件，不是 Minis 提示词包。Cordis/JS/UI/Tools 运行时尚未适配；不会执行或假装安装成功。prompt-custom.json 可单独导入为数据。")
            }
            throw PluginError.missingManifest
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginError.invalidManifest(error.localizedDescription)
        }
        try validate(manifest)

        // Validate/read everything before touching an installed version.
        let prompts = try PluginPackageIO.promptFiles(manifest: manifest, root: source)
        let root = Self.pluginsRootDir
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        let staged = root.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staged) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staged.appendingPathComponent(manifestName), options: .atomic)
        for (file, bytes) in prompts {
            let target = staged.appendingPathComponent(file)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
        let previousState = readStates()[manifest.id]
        if fm.fileExists(atPath: destination.path) {
            let attrs = try fm.attributesOfItem(atPath: destination.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else {
                throw PluginError.invalidManifest("destination is not a real plugin directory")
            }
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        // Import never grants prompt permissions, including an update.
        let state = PluginState(enabled: false, activeModules: previousState?.activeModules)
        var states = readStates()
        states[manifest.id] = state
        writeStates(states)

        reload()
        return plugins.first(where: { $0.id == manifest.id }) ?? InstalledPlugin(
            manifest: manifest,
            directoryURL: destination,
            state: state
        )
    }

    @discardableResult
    func installDSHPrompt(_ conversion: DSHPromptImporter.Conversion) throws -> InstalledPlugin {
        let temporary = fm.temporaryDirectory.appendingPathComponent("dsh-import-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        try JSONEncoder().encode(conversion.manifest).write(to: temporary.appendingPathComponent("plugin.json"), options: .atomic)
        for (file, text) in conversion.files {
            let target = temporary.appendingPathComponent(file)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: target, atomically: true, encoding: .utf8)
        }
        return try install(fromDirectory: temporary)
    }

    func uninstall(_ pluginId: String) {
        guard let plugin = plugins.first(where: { $0.id == pluginId }) else { return }
        try? fm.removeItem(at: plugin.directoryURL)
        var states = readStates()
        states.removeValue(forKey: pluginId)
        writeStates(states)
        reload()
    }

    private func validate(_ manifest: PluginManifest) throws {
        // The id becomes a directory name; keep it from escaping the root.
        let pattern = "^[a-z0-9][a-z0-9._-]{1,63}$"
        guard manifest.id.range(of: pattern, options: .regularExpression) != nil else {
            throw PluginError.invalidId(manifest.id)
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError.invalidManifest("name is empty")
        }
        guard !manifest.modules.isEmpty else {
            throw PluginError.invalidManifest("no modules declared")
        }
        var seen = Set<String>()
        for module in manifest.modules {
            guard module.id.range(of: pattern, options: .regularExpression) != nil,
                  !module.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  module.file.hasPrefix("prompts/"), module.file.hasSuffix(".md") else {
                throw PluginError.invalidManifest("invalid prompt module metadata")
            }
            guard seen.insert(module.id).inserted else {
                throw PluginError.invalidManifest("duplicate module id: \(module.id)")
            }
            if module.file.hasPrefix("/") || module.file.contains("..") {
                throw PluginError.invalidManifest("module path escapes the package: \(module.file)")
            }
        }
    }

    // MARK: Prompt assembly

    /// The text injected into the system prompt. Nil when nothing is enabled,
    /// so callers can skip the concatenation entirely.
    ///
    /// Read from disk on every call: a user editing prompts in place expects
    /// the next turn to pick it up, and these files are small.
    func promptFragment() -> String? {
        var sections: [String] = []
        var used = 0

        for plugin in plugins where plugin.isEnabled {
            let modules = plugin.activeModules
            if modules.isEmpty { continue }

            var body: [String] = []
            var pluginUsed = 0

            for module in modules {
                guard let bytes = try? PluginPackageIO.checkedFile(module.file, in: plugin.directoryURL, limit: 128 * 1024),
                      let raw = String(data: bytes, encoding: .utf8) else {
                    AppLogger(category: "PluginStore")
                        .info("[Prompt] \(plugin.id): missing \(module.file)")
                    continue
                }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }

                let remaining = Self.perPluginCharLimit - pluginUsed
                if remaining <= 0 { break }
                let clipped = text.count > remaining ? String(text.prefix(remaining)) : text
                pluginUsed += clipped.count
                body.append(clipped)
            }

            if body.isEmpty { continue }

            let versionSuffix = plugin.manifest.version.isEmpty ? "" : " v\(plugin.manifest.version)"
            let header = "## Plugin: \(plugin.manifest.name)" + versionSuffix
            var section = header + "\n"
            if let description = plugin.manifest.description, !description.isEmpty {
                section += description + "\n"
            }
            section += body.joined(separator: "\n\n")

            let remaining = Self.totalCharLimit - used
            if remaining <= 0 { break }
            if section.count > remaining {
                section = String(section.prefix(remaining))
            }
            used += section.count
            sections.append(section)
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }
}

// MARK: - Errors

enum PluginError: LocalizedError {
    case missingManifest
    case invalidManifest(String)
    case invalidId(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return AppLocalized("This folder is not a plugin: plugin.json is missing.")
        case .invalidManifest(let reason):
            return AppLocalized("Invalid plugin manifest: ") + reason
        case .invalidId(let id):
            return AppLocalized("Invalid plugin id: ") + id
        }
    }
}