import Foundation

enum BundledModelCatalog {
    static let names: [String] = load()

    private static func load() -> [String] {
        guard let url = Bundle.main.url(forResource: "model-catalog", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var seen = Set<String>()
        return text
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let name = String(line)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{FEFF}", with: "")
                guard !name.isEmpty,
                      !name.hasPrefix("#"),
                      seen.insert(name).inserted else {
                    return nil
                }
                return name
            }
    }
}
