import SwiftUI

@MainActor
struct SettingsView: View {
    let productInfo: ProductInfo
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("editor.fontSize") private var fontSize = 14.0
    @AppStorage("editor.wrap") private var wrap = true
    @AppStorage("editor.autoSave") private var autoSave = true
    @AppStorage("files.showHidden") private var showHidden = false
    @AppStorage("files.exclusions") private var exclusions = ""
    @AppStorage("image.jpegQuality") private var jpegQuality = 0.9

    var body: some View {
        Form {
            LabeledContent("settings.application") {
                Text(productInfo.name)
            }

            LabeledContent("settings.minimumSystem") {
                Text(productInfo.minimumSystemVersion)
            }

            Picker("settings.appearance", selection: $appearance) {
                Text("settings.system").tag("system")
                Text("settings.light").tag("light")
                Text("settings.dark").tag("dark")
            }
            Stepper("settings.fontSize \(Int(fontSize))", value: $fontSize, in: 10...32)
            Toggle("settings.wrap", isOn: $wrap)
            Toggle("settings.autoSave", isOn: $autoSave)
            Toggle("settings.showHidden", isOn: $showHidden)
            TextField("settings.exclusions", text: $exclusions)
            Text("settings.filesRestart").font(.caption).foregroundStyle(.secondary)
            Slider(value: $jpegQuality, in: 0.1...1, step: 0.05) {
                Text("settings.jpegQuality")
            }
            Text(jpegQuality, format: .percent)
            Text("settings.privacy").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .navigationTitle("settings.title")
    }
}

