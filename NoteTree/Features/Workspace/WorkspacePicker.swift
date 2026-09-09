import AppKit

@MainActor
protocol WorkspacePicking {
    func pickWorkspace() -> URL?
}

@MainActor
struct SystemWorkspacePicker: WorkspacePicking {
    func pickWorkspace() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "workspacePicker.title")
        panel.message = String(localized: "workspacePicker.message")
        panel.prompt = String(localized: "workspacePicker.open")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false

        return panel.runModal() == .OK ? panel.url : nil
    }
}
