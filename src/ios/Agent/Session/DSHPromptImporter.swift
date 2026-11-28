import Foundation

/// Data-only compatibility, not a Cordis/Node/React plugin runtime.
/// No JavaScript is evaluated during inspection or conversion.
enum DSHPromptImporter {
    struct Card: Decodable { let id: String; let name: String; let text: String }
    struct Input: Decodable {
        let enabled: Bool?
        let mode: String?
        let text: String?
        let cards: [Card]?
    }
    struct Conversion {
        let manifest: PluginManifest
        let files: [String: String]
        let report: String
    }
    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let reason): return "DSH 导入被拒绝：" + reason }
        }
    }
    static func convert(_ data: Data) throws -> Conversion {
        guard data.count <= 256 * 1024 else { throw ImportError.invalid("配置超过 256 KiB。") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalid("必须是 prompt-custom JSON 对象。")
        }
        let allowed: Set<String> = ["enabled", "mode", "text", "cards"]
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ImportError.invalid("不支持这些字段（需要 DSH 运行时，未安装）：" + unknown.sorted().joined(separator: ", "))
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.mode == nil || ["append", "replace"].contains(input.mode!) else {
            throw ImportError.invalid("未知 mode。")
        }
        let cards = input.cards ?? []
        guard cards.count <= 100 else { throw ImportError.invalid("卡片超过 100 张。") }
        var ids = Set<String>()
        var files: [String: String] = [:]
        var modules: [PluginModule] = []
        let current = (input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            modules.append(PluginModule(id: "live", name: "当前提示词", file: "prompts/live.md", isDefault: true))
            files["prompts/live.md"] = current
        }
        for (index, card) in cards.enumerated() {
            guard !card.id.isEmpty, card.id.count <= 64, ids.insert(card.id).inserted,
                  !card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.invalid("卡片 id 重复、为空或卡片内容无效。")
            }
            let id = "card-\(index + 1)"
            let file = "prompts/\(id).md"
            files[file] = card.text
            modules.append(PluginModule(id: id, name: card.name, file: file, isDefault: false))
        }
        guard !modules.isEmpty else { throw ImportError.invalid("没有可导入的提示词。") }
        guard files.values.reduce(0, { $0 + $1.count }) <= 32_000 else {
            throw ImportError.invalid("所有提示词与卡片合计超过 32,000 字符，请拆包。")
        }
        let report = "仅兼容 DSH prompt-custom 数据：当前 text 与提示词卡。安装后默认禁用，需手动启用。卡片用作独立可选模块。DSH 的 replace 模式在 Minis 中只作为附加插件节，不替换核心人设。Cordis JavaScript、工具注册、生命周期 Hook、Web UI、知识库与 API 均未执行、未适配。"
        let manifest = PluginManifest(schemaVersion: 1, id: "dsh.prompt-custom", name: "DSH Prompt Custom（数据兼容）", version: "1.0.0", description: report, author: nil, priority: nil, modules: modules, profiles: nil)
        return Conversion(manifest: manifest, files: files, report: report)
    }
}
