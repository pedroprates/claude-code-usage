import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var openRouter: OpenRouterService
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput: String = ""
    @State private var savedKey: Bool = false
    @State private var bridgeInstalled: Bool = false
    @State private var bridgeActivated: Bool = false
    @State private var bridgeBusy: Bool = false
    @State private var bridgeError: String?

    var body: some View {
        Form {
            Section("Statusline bridge") {
                HStack {
                    Image(systemName: bridgeInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(bridgeInstalled ? .green : .yellow)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bridgeInstalled
                             ? (bridgeActivated ? "Installed" : "Installed (bypassed)")
                             : "Not installed")
                            .font(.system(size: 12, weight: .semibold))
                        Text(bridgeInstalled
                             ? "Live usage data flows from Claude Code."
                             : "Required for the menu bar to receive live data.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if bridgeBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(bridgeInstalled ? "Uninstall" : "Install") {
                            toggleBridge()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let err = bridgeError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: "ff453a"))
                }
            }

            Section("Thresholds") {
                HStack {
                    Text("Warn at")
                    Spacer()
                    TextField("", value: $settings.warnThreshold, format: .percent.precision(.fractionLength(0)))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Danger at")
                    Spacer()
                    TextField("", value: $settings.dangerThreshold, format: .percent.precision(.fractionLength(0)))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Notifications at danger", isOn: $settings.notificationsEnabled)
            }

            Section("OpenRouter") {
                SecureField("API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .onAppear {
                        apiKeyInput = KeychainStore.get(account: OpenRouterService.account) ?? ""
                        savedKey = !apiKeyInput.isEmpty
                    }

                HStack {
                    if savedKey {
                        Label("Key stored in Keychain", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil {
                        Label("Using OPENROUTER_API_KEY env var", systemImage: "terminal.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Button("Save") {
                        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            KeychainStore.remove(account: OpenRouterService.account)
                        } else {
                            KeychainStore.set(trimmed, account: OpenRouterService.account)
                        }
                        savedKey = !trimmed.isEmpty
                        Task { await openRouter.refresh() }
                    }
                    .buttonStyle(.borderedProminent)

                    if savedKey {
                        Button("Remove") {
                            KeychainStore.remove(account: OpenRouterService.account)
                            apiKeyInput = ""
                            savedKey = false
                        }
                    }
                }
                .font(.caption)

                Link("Get a key at openrouter.ai/keys",
                     destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .navigationTitle("CC Usage Tracker")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            bridgeInstalled = BridgeInstaller.shared.isInstalled
            bridgeActivated = BridgeInstaller.shared.isActivated
        }
    }

    private func toggleBridge() {
        bridgeBusy = true
        bridgeError = nil
        Task {
            do {
                if bridgeInstalled {
                    try BridgeInstaller.shared.uninstall()
                } else {
                    try BridgeInstaller.shared.install()
                }
                bridgeInstalled = BridgeInstaller.shared.isInstalled
                bridgeActivated = BridgeInstaller.shared.isActivated
            } catch {
                bridgeError = error.localizedDescription
            }
            bridgeBusy = false
        }
    }
}
