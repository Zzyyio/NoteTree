import Foundation

struct FileTreeExclusionPolicy: Sendable {
    var showHidden = false
    var patterns: [String] = []
    private let excludedNames: Set<String> = [".git", ".build", "DerivedData", "build"]

    func shouldExclude(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if (!showHidden && name.hasPrefix(".")) || excludedNames.contains(name) {
            return true
        }
        if patterns.contains(where: { pattern in
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            return name.range(of: "^\(escaped)$", options: .regularExpression) != nil
        }) { return true }

        let values = try? url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
        return (!showHidden && values?.isHidden == true) || values?.isPackage == true
    }
}
