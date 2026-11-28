import SwiftUI
import UniformTypeIdentifiers

struct DSHPromptImportView: View {
    @State private var showImporter = false
    @State private var pending: DSHPromptImporter.Conversion?
    @State private var error: String?
    @State private var installed = false

    var body: some View {
        Form {
            Section("兼容范围") {
                Text("导入 DSH prompt-custom.json 的 text 与提示词卡，不执行 JavaScript。")
                Text("Cordis 插件、工具注册、生命周期 Hook、React 插件界面、API 与知识库尚不兼容。npm 包不会被当成安装成功。")
                    .foregroundStyle(.secondary)
                Button("选择 prompt-custom.json") { showImporter = true }
            }
            if let conversion = pending {
                Section("导入预览与权限") {
                    Text(conversion.report)
                    Text("模块：\(conversion.manifest.modules.count)；将安装为 dsh.prompt-custom。已存在的同名包会被替换，且重新变为禁用。")
                    Button("确认导入（保持禁用）") {
                        do {
                            try PluginStore.shared.installDSHPrompt(conversion)
                            pending = nil
                            installed = true
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            if installed {
                Section { Text("已导入且未启用。返回插件列表检查模块后，手动开启。") }
            }
            if let error { Section("未导入") { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("DSH 数据兼容导入")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure(let failure): error = failure.localizedDescription
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let size = values.fileSize, size <= 256 * 1024 else {
                        throw DSHPromptImporter.ImportError.invalid("必须选择不超过 256 KiB 的普通 JSON 文件。")
                    }
                    pending = try DSHPromptImporter.convert(Data(contentsOf: url))
                    error = nil
                    installed = false
                } catch { self.error = error.localizedDescription; pending = nil }
            }
        }
    }
}
