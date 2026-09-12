import SwiftUI

/// Settings screen for managing company-identification sources.
///
/// The user can:
///   - enable/disable each source (toggle)
///   - enter an API key if required (SecureField, persisted in UserDefaults)
///   - see the covered country (ISO badge)
///   - see the "Coming soon" state for placeholders not yet implemented
///   - open the sign-up link (apiKeyHelpURL) to get a key
struct CompanyDataSourcesSettingsView: View {
    @Bindable private var registry = CompanyDataSourcesRegistry.shared
    @State private var revealedKeys: Set<String> = []
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Text("Quand tu utilises l'aide à l'identification dans l'import, ces sources sont interrogées en parallèle pour proposer des correspondances. Le filtrage par pays se fait automatiquement selon le tier.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } header: { Text("À propos") }

            ForEach(Array(registry.allKnownSources.enumerated()), id: \.element.id) { _, source in
                sourceSection(source)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nouvelles sources ?").font(.caption.bold())
                    Text("A l'avenir de nouvelles sources d'identification d'entreprise selon les pays seront ajoutées ici.")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } header: { Text("Information supplémentaire") }
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .localizedNavigationTitle("Sources entreprises")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sourceSection(_ source: any CompanyDataSource) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { registry.isEnabled(source) },
                set: { registry.setEnabled(source, enabled: $0) }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: source.isImplemented ? "checkmark.seal.fill" : "hourglass")
                        .foregroundStyle(source.isImplemented ? AppTheme.Colors.accent : AppTheme.Colors.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(LocalizedStringKey(source.displayName)).font(.subheadline.weight(.semibold))
                            if let country = source.country {
                                Text(country)
                                    .font(.caption2.monospaced().weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(AppTheme.Colors.accent.opacity(0.15), in: Capsule())
                                    .foregroundStyle(AppTheme.Colors.accent)
                            } else {
                                Text("Global")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(AppTheme.Colors.textSecondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        if !source.isImplemented {
                            Text("⏳ Bientôt — l'implémentation est en cours")
                                .font(.caption2).foregroundStyle(AppTheme.Colors.warning)
                        }
                    }
                }
            }
            .disabled(!source.isImplemented)

            if source.requiresAPIKey && registry.isEnabled(source) {
                apiKeyField(source)
            }

            if let helpURL = source.apiKeyHelpURL {
                Button {
                    openURL(helpURL)
                } label: {
                    Label(source.requiresAPIKey ? "Obtenir une clé API" : "Site officiel",
                          systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func apiKeyField(_ source: any CompanyDataSource) -> some View {
        let isRevealed = revealedKeys.contains(source.id)
        let currentKey = registry.apiKey(for: source) ?? ""

        HStack {
            Group {
                if isRevealed {
                    TextField("Clé API…", text: Binding(
                        get: { currentKey },
                        set: { registry.setAPIKey(source, key: $0) }
                    ))
                } else {
                    SecureField("Clé API…", text: Binding(
                        get: { currentKey },
                        set: { registry.setAPIKey(source, key: $0) }
                    ))
                }
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.caption, design: .monospaced))

            Button {
                if isRevealed { revealedKeys.remove(source.id) }
                else { revealedKeys.insert(source.id) }
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    NavigationStack {
        CompanyDataSourcesSettingsView()
    }
}
