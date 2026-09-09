import Foundation

struct FileTreeExclusionPolicy: Sendable {
    private let excludedNames: Set<String> = [".git", ".build", "DerivedData", "build"]

    func shouldExclude(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") || excludedNames.contains(name) {
            return true
        }

        let values = try? url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
        return values?.isHidden == true || values?.isPackage == true
    }
}
