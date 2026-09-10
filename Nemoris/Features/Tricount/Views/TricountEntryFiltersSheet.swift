import SwiftUI

/// Ordre d'affichage des dépenses d'un Tricount. `.dateDesc` reproduit
/// le comportement historique (ordre SQL de `TricountRepository.fetchEntries`).
enum TricountEntrySort: String, CaseIterable, Identifiable {
    case dateDesc  = "Date (récent → ancien)"
    case dateAsc   = "Date (ancien → récent)"
    case titleAsc  = "Titre (A → Z)"
    case titleDesc = "Titre (Z → A)"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dateDesc, .dateAsc: return "calendar"
        case .titleAsc, .titleDesc: return "textformat"
        }
    }
}

/// Filtre "liée à une transaction" — cf. `TricountEntry.linkedTransactionId`,
/// distinct des remboursements (cf. commentaire de `TricountDetailView`).
enum TricountLinkFilter: String, CaseIterable, Identifiable {
    case all       = "Toutes"
    case linked    = "Liées"
    case notLinked = "Non liées"

    var id: String { rawValue }
}

struct TricountEntryFiltersSheet: View {
    @Environment(\.paneDismiss) private var paneDismiss

    /// Noms bruts des payeurs présents dans le groupe (`TricountEntry.whoPaid`),
    /// dédupliqués et triés par l'appelant.
    let payerOptions: [String]
    /// "Moi" pour `group.myName`, le nom brut sinon — même convention que
    /// `TricountEntryRow.isPaidByMe`.
    let payerDisplayName: (String) -> String
    let currency: String
    /// Bornes réelles des dates de dépenses du groupe — cadre le `DatePicker`
    /// et sert de valeurs par défaut à l'activation du filtre (période
    /// complète plutôt que "aujourd'hui" des deux côtés, qui masquerait tout).
    let minDate: Date
    let maxDate: Date

    @Binding var titleSearchText: String
    @Binding var linkFilter: TricountLinkFilter
    /// "" = tous les payeurs.
    @Binding var payerFilter: String
    @Binding var minShareText: String
    @Binding var maxShareText: String
    @Binding var dateFilterEnabled: Bool
    @Binding var fromDate: Date
    @Binding var toDate: Date

    let onApply: () -> Void

    // Copies locales — évite de re-rendre la liste filtrée à chaque frappe
    // (texte) ou à chaque glissement de roue (dates).
    @State private var localTitleSearch = ""
    @State private var localMinShare = ""
    @State private var localMaxShare = ""
    @State private var localDateFilterEnabled = false
    @State private var localFromDate = Date()
    @State private var localToDate = Date()

    var body: some View {
        Form {
            Section("Recherche") {
                TextField("Titre…", text: $localTitleSearch)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section {
                Toggle("Filtrer par période", isOn: $localDateFilterEnabled)
                if localDateFilterEnabled {
                    DatePicker("Du", selection: $localFromDate, in: minDate...maxDate, displayedComponents: .date)
                    DatePicker("Au", selection: $localToDate, in: minDate...maxDate, displayedComponents: .date)
                }
            } header: {
                Text("Période")
            }

            Section {
                Picker("Lien transaction", selection: $linkFilter) {
                    ForEach(TricountLinkFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Lien transaction")
            } footer: {
                Text("Une dépense liée est rapprochée d'une transaction bancaire (icône ✓ verte dans la liste).")
            }

            if !payerOptions.isEmpty {
                Section("Payeur") {
                    Picker("Payeur", selection: $payerFilter) {
                        Text("Tous").tag("")
                        ForEach(payerOptions, id: \.self) { name in
                            Text(payerDisplayName(name)).tag(name)
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("Min", text: $localMinShare)
                        .keyboardType(.decimalPad)
                    Text("–").foregroundStyle(AppTheme.Colors.textSecondary)
                    TextField("Max", text: $localMaxShare)
                        .keyboardType(.decimalPad)
                }
            } header: {
                Text("Ma part (\(currency))")
            } footer: {
                Text("Filtre sur le montant absolu de ta part dans la dépense. Laisse un champ vide pour ne pas le borner.")
            }

            Section {
                Button("Réinitialiser les filtres") {
                    localTitleSearch = ""
                    localMinShare = ""
                    localMaxShare = ""
                    localDateFilterEnabled = false
                    localFromDate = minDate
                    localToDate = maxDate
                    titleSearchText = ""
                    linkFilter = .all
                    payerFilter = ""
                    minShareText = ""
                    maxShareText = ""
                    dateFilterEnabled = false
                    fromDate = minDate
                    toDate = maxDate
                }
                .foregroundStyle(AppTheme.Colors.danger)
            }
        }
        .nemorisFormStyle()
        .onAppear {
            localTitleSearch = titleSearchText
            localMinShare = minShareText
            localMaxShare = maxShareText
            localDateFilterEnabled = dateFilterEnabled
            localFromDate = dateFilterEnabled ? fromDate : minDate
            localToDate = dateFilterEnabled ? toDate : maxDate
        }
        .paneChrome(
            "Filtres",
            cancelLabel: "Fermer", onCancel: { paneDismiss() },
            confirmLabel: "Appliquer", confirmIcon: "checkmark",
            onConfirm: {
                titleSearchText = localTitleSearch
                minShareText = localMinShare
                maxShareText = localMaxShare
                dateFilterEnabled = localDateFilterEnabled
                fromDate = localFromDate
                toDate = localToDate
                onApply()
                paneDismiss()
            }
        )
    }
}
