import Foundation

/// Only manifest + declared UTF-8 prompt files cross the installation boundary.
/// Unknown JS/native files are never copied or executed.
enum PluginPackageIO {
    static func checkedFile(_ relative: String, in root: URL, limit: Int) throws -> Data {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              !relative.unicodeScalars.contains(where: { $0.value < 32 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PluginError.invalidManifest("unsafe relative path")
        }
        let fm = FileManager.default
        var current = root.standardizedFileURL
        let rootAttrs = try fm.attributesOfItem(atPath: current.path)
        guard rootAttrs[.type] as? FileAttributeType == .typeDirectory else {
            throw PluginError.invalidManifest("package root must be a real directory")
        }
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            let attrs = try fm.attributesOfItem(atPath: current.path)
            let type = attrs[.type] as? FileAttributeType
            guard type == (index == parts.count - 1 ? .typeRegular : .typeDirectory) else {
                throw PluginError.invalidManifest("symlinks and non-regular package files are not allowed")
            }
            if index == parts.count - 1 {
                guard let size = attrs[.size] as? NSNumber, size.intValue <= limit else {
                    throw PluginError.invalidManifest("package file exceeds its byte budget")
                }
            }
        }
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        guard current.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) else {
            throw PluginError.invalidManifest("package path escapes root")
        }
        let data = try Data(contentsOf: current, options: [.mappedIfSafe])
        guard data.count <= limit else { throw PluginError.invalidManifest("package file changed or exceeded budget") }
        return data
    }

    static func promptFiles(manifest: PluginManifest, root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        var count = 0
        for module in manifest.modules {
            let data = try checkedFile(module.file, in: root, limit: 128 * 1024)
            guard let text = String(data: data, encoding: .utf8) else {
                throw PluginError.invalidManifest("prompt is not UTF-8")
            }
            count += text.count
            guard count <= 32_000 else { throw PluginError.invalidManifest("prompt package exceeds 32,000 characters") }
            result[module.file] = data
        }
        return result
    }
}
