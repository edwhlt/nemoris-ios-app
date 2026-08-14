import SwiftUI

/// Sheet de conversation avec l'assistant SQL.
/// Multi-tours : chaque question raffine la requête précédente (l'IA garde le contexte).
/// Pour chaque réponse contenant un bloc SQL, 2 boutons :
///   - "Utiliser cette requête" → colle dans l'éditeur parent et dismiss
///   - "Tester maintenant" → exécute la requête et affiche le résultat tronqué inline
struct SQLAssistantSheet: View {
    /// Callback appelé quand l'utilisateur confirme "Utiliser cette requête" — après
    /// avoir éventuellement ajusté le titre suggéré dans l'alerte de confirmation.
    let onApply: (_ title: String, _ sql: String) -> Void

    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @State private var service = SQLAssistantService()
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isThinking = false
    /// SQL en attente de confirmation de titre (déclenché par "Utiliser cette
    /// requête"). Non-nil ⇒ l'alerte de titre est présentée.
    @State private var pendingApplySQL: String? = nil
    @State private var titleInput: String = ""

    private let repository = TransactionRepository()

    enum Role { case user, assistant }
    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: Role
        var text: String
        /// Résultat d'un "Tester maintenant" si l'utilisateur l'a déclenché.
        var inlineResult: InlineResult? = nil
    }
    struct InlineResult {
        let columns: [String]
        let rows: [[String]]
        let truncated: Bool
        let error: String?
    }

    var body: some View {
            Group {
                switch service.availability {
                case .ready:
                    chatBody
                case .notImplemented:
                    unavailableState(
                        title: "Nécessite iOS 26+",
                        message: "L'assistant utilise Apple Foundation Models qui n'est disponible qu'à partir d'iOS 26."
                    )
                case .appleIntelligenceOff:
                    unavailableState(
                        title: "Apple Intelligence désactivé",
                        message: "Activez Apple Intelligence dans Réglages › Apple Intelligence & Siri pour utiliser l'assistant."
                    )
                case .deviceNotEligible:
                    unavailableState(
                        title: "Appareil non compatible",
                        message: "Foundation Models requiert un appareil supportant Apple Intelligence."
                    )
                case .modelNotReady:
                    unavailableState(
                        title: "Modèle en téléchargement",
                        message: "Le modèle d'IA est en cours de téléchargement. Réessayez dans quelques minutes."
                    )
                }
            }
            .paneChrome("Assistant SQL",
                        cancelLabel: "Fermer", onCancel: { dismiss() },
                        confirmLabel: (service.availability == .ready && !messages.isEmpty) ? "Nouvelle conversation" : nil,
                        confirmIcon: "square.and.pencil",
                        onConfirm: (service.availability == .ready && !messages.isEmpty) ? {
                            service.resetConversation()
                            messages = []
                        } : nil)
            .alert("Titre de la section", isPresented: Binding(
                get: { pendingApplySQL != nil },
                set: { if !$0 { pendingApplySQL = nil } }
            )) {
                TextField("Titre", text: $titleInput)
                Button("Insérer") {
                    if let sql = pendingApplySQL {
                        onApply(titleInput, sql)
                    }
                    pendingApplySQL = nil
                    dismiss()
                }
                Button("Annuler", role: .cancel) { pendingApplySQL = nil }
            } message: {
                Text("Devient l'en-tête « -- titre -- » de cette section dans le fichier .sql.")
            }
    }

    // MARK: - Chat body

    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.md) {
                        if messages.isEmpty {
                            welcomeCard
                                .padding(.top, AppTheme.Spacing.xl)
                        } else {
                            ForEach(messages) { msg in
                                messageBubble(msg)
                                    .id(msg.id)
                            }
                        }
                        if isThinking {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("L'assistant réfléchit…")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, AppTheme.Spacing.lg)
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.md)
                }
                .background(AppTheme.Colors.background)
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            inputBar
        }
    }

    private var welcomeCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(AppTheme.Colors.accent)
                    Text("Comment ça marche")
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                Text("Décrivez ce que vous voulez extraire de votre base, dans la langue de votre choix. L'assistant génère la requête SQL pour vous. Vous pouvez la raffiner par questions successives.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Divider()
                Text("Exemples")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                ForEach([
                    "Mes 10 plus grosses dépenses ce mois",
                    "Combien j'ai dépensé en alimentation cette année",
                    "Liste des tiers utilisés depuis 6 mois",
                    "Solde total de tous mes comptes"
                ], id: \.self) { example in
                    Button {
                        inputText = example
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.left.circle")
                                .font(.caption)
                            Text(example)
                                .font(.caption)
                            Spacer()
                        }
                        .foregroundStyle(AppTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
    }

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer()
                Text(msg.text)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(AppTheme.Colors.accent, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: 280, alignment: .trailing)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
        case .assistant:
            assistantBubble(msg)
                .padding(.horizontal, AppTheme.Spacing.md)
        }
    }

    @ViewBuilder
    private func assistantBubble(_ msg: ChatMessage) -> some View {
        let parts = parseAssistantResponse(msg.text)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if !parts.prose.isEmpty {
                Text(parts.prose)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
            if let sql = parts.sql {
                Text(sql)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(AppTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.Colors.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .textSelection(.enabled)

                HStack(spacing: AppTheme.Spacing.sm) {
                    Button {
                        titleInput = suggestedTitle(for: msg.id)
                        pendingApplySQL = sql
                    } label: {
                        Label("Utiliser cette requête", systemImage: "arrow.down.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(AppTheme.Colors.accent)

                    Button {
                        testQuery(sql, in: msg.id)
                    } label: {
                        Label("Tester", systemImage: "play.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(AppTheme.Colors.accent)
                }
            }
            if let result = msg.inlineResult {
                inlineResultView(result)
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.surfaceSecondary, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func inlineResultView(_ result: InlineResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if let err = result.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.danger)
            } else {
                Text("Résultat (\(result.rows.count) ligne\(result.rows.count > 1 ? "s" : "")\(result.truncated ? ", tronqué" : ""))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            ForEach(Array(result.columns.enumerated()), id: \.offset) { _, col in
                                Text(col)
                                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 12) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(AppTheme.Colors.textPrimary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, AppTheme.Spacing.xs)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: AppTheme.Spacing.sm) {
            TextField("Décrivez votre requête…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                // Le champ étant multi-ligne (axis: .vertical), Retour insère un
                // saut de ligne — comportement conservé. macOS dessine par défaut
                // un anneau de focus SYSTÈME par-dessus le fond custom arrondi
                // ci-dessous, qui jure visuellement ; désactivé pour ne garder que
                // ce fond comme indicateur de focus (iOS : no-op).
                .focusEffectDisabled()
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background(AppTheme.Colors.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary.opacity(0.4))
            }
            .disabled(!canSend)
            // ⌘Retour envoie, en plus du tap — convention macOS standard pour un
            // champ de texte multi-ligne où Retour seul reste un saut de ligne.
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Envoyer (⌘Retour)")
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface)
    }

    private var canSend: Bool {
        !isThinking && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func sendMessage() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isThinking else { return }
        inputText = ""
        messages.append(ChatMessage(role: .user, text: prompt))
        isThinking = true

        Task {
            let response = await service.send(prompt)
            let answer = response ?? "⚠️ L'IA n'a pas pu générer de réponse. Vérifie que Apple Intelligence est activé et que le modèle est téléchargé (Réglages › Apple Intelligence & Siri). Sinon, réessaie en reformulant."
            messages.append(ChatMessage(role: .assistant, text: answer))
            isThinking = false
        }
    }

    private func testQuery(_ sql: String, in messageId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let repo = repository
        Task.detached(priority: .userInitiated) {
            let outcome = repo.executeSQL(sql)
            await MainActor.run {
                guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
                _ = index  // silence warning
                switch outcome {
                case .success(let res):
                    let capped = Array(res.rows.prefix(5))
                    messages[idx].inlineResult = InlineResult(
                        columns: res.columns,
                        rows: capped,
                        truncated: res.rows.count > 5,
                        error: nil
                    )
                case .failure(let err):
                    messages[idx].inlineResult = InlineResult(
                        columns: [], rows: [], truncated: false, error: err.message
                    )
                }
            }
        }
    }

    /// Dérive un titre par défaut depuis la question de l'utilisateur qui a produit
    /// cette réponse — déjà en langage naturel, donc un bon point de départ pour
    /// l'en-tête `-- titre --` de la section SQL insérée dans le fichier.
    private func suggestedTitle(for messageId: UUID) -> String {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }), idx > 0,
              messages[idx - 1].role == .user else { return "" }
        var title = messages[idx - 1].text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "--", with: "–")
        if title.count > 60 {
            title = String(title.prefix(60)) + "…"
        }
        return title
    }

    // MARK: - Unavailable state

    @ViewBuilder
    private func unavailableState(title: String, message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: "sparkles.slash")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            Text(title)
                .font(AppTheme.Typography.titleMedium)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Text(message)
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.xxxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Colors.background)
    }

    // MARK: - Parsing helpers

    /// Extrait le bloc ```sql ... ``` (ou ``` ... ``` générique) et le reste comme prose.
    private func parseAssistantResponse(_ text: String) -> (prose: String, sql: String?) {
        let pattern = "```(?:sql)?\\s*([\\s\\S]*?)```"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (text, nil)
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = re.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2 else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let sql = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prose = (ns.substring(with: NSRange(location: 0, length: match.range.location))
            + " "
            + ns.substring(from: match.range.upperBound))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prose, sql.isEmpty ? nil : sql)
    }
}
