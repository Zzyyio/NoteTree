import AppKit

@MainActor
protocol FileURLCopying {
    func copyFileURL(_ url: URL)
}

@MainActor
struct SystemFileURLClipboard: FileURLCopying {
    func copyFileURL(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}
