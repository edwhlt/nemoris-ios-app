import SwiftUI

/// Display order for a Tricount's expenses. `.dateDesc` reproduces
/// the historical behavior (the SQL order of `TricountRepository.fetchEntries`).
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

/// A "linked to a transaction" filter — see `TricountEntry.linkedTransactionId`,
/// distinct from reimbursements (see `TricountDetailView`'s comment).
enum TricountLinkFilter: String, CaseIterable, Identifiable {
    case all       = "Toutes"
    case linked    = "Liées"
    case notLinked = "Non liées"

    var id: String { rawValue }
}

struct TricountEntryFiltersSheet: View {
    @Environment(\.paneDismiss) private var paneDismiss

    /// Raw names of payers present in the group (`TricountEntry.whoPaid`),
    /// deduplicated and sorted by the caller.
    let payerOptions: [String]
    /// "Me" for `group.myName`, the raw name otherwise — the same convention as
    /// `TricountEntryRow.isPaidByMe`.
    let payerDisplayName: (String) -> String
    let currency: String
    /// The group's expenses' real date bounds — frames the `DatePicker`
    /// and serves as the default values when the filter is activated (the full
    /// period rather than "today" on both ends, which would hide everything).
    let minDate: Date
    let maxDate: Date

    @Binding var titleSearchText: String
    @Binding var linkFilter: TricountLinkFilter
    /// "" = every payer.
    @Binding var payerFilter: String
    @Binding var minShareText: String
    @Binding var maxShareText: String
    @Binding var dateFilterEnabled: Bool
    @Binding var fromDate: Date
    @Binding var toDate: Date

    let onApply: () -> Void

    // Local copies — avoids re-rendering the filtered list on every
    // keystroke (text) or every wheel scroll (dates).
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
