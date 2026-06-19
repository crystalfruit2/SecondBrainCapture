import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var config: AppConfig
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub token") {
                    SecureField(config.hasToken ? "Saved — paste to replace" : "Fine-grained PAT",
                                text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if config.hasToken {
                        Button("Remove saved token", role: .destructive) {
                            config.setToken("")
                            tokenInput = ""
                            testResult = nil
                        }
                    }
                }

                Section("Repository") {
                    LabeledField("Owner", text: $config.owner)
                    LabeledField("Repo", text: $config.repo)
                    LabeledField("Branch", text: $config.branch)
                    LabeledField("Folder", text: $config.folder)
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)

                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(testResult.hasPrefix("✅") ? .green : .red)
                    }
                }

                Section {
                    Text("The token needs **Contents: read/write** on this repo. Notes are written to \(config.folder)/ as new timestamped files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
            }
        }
    }

    private func save() {
        if !tokenInput.isEmpty { config.setToken(tokenInput) }
    }

    private func test() async {
        save()
        testing = true
        testResult = nil
        let service = GitHubService(config: config.githubConfig, token: config.token)
        do {
            try await service.testConnection()
            testResult = "✅ Connected to \(config.owner)/\(config.repo)"
        } catch {
            testResult = "⚠️ " + error.localizedDescription
        }
        testing = false
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String

    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}
