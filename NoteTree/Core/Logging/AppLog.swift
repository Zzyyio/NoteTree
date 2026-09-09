import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.NoteTree"

    static let application = Logger(subsystem: subsystem, category: "application")
    static let workspace = Logger(subsystem: subsystem, category: "workspace")
    static let fileSystem = Logger(subsystem: subsystem, category: "filesystem")
    static let markdown = Logger(subsystem: subsystem, category: "markdown")
    static let pdf = Logger(subsystem: subsystem, category: "pdf")
    static let image = Logger(subsystem: subsystem, category: "image")
}
