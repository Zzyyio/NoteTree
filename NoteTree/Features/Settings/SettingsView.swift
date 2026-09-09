import SwiftUI

@MainActor
struct SettingsView: View {
    let productInfo: ProductInfo

    var body: some View {
        Form {
            LabeledContent("settings.application") {
                Text(productInfo.name)
            }

            LabeledContent("settings.minimumSystem") {
                Text(productInfo.minimumSystemVersion)
            }

            Text("settings.phaseZero.description")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .navigationTitle("settings.title")
    }
}

