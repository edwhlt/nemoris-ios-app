import SwiftUI
import TipKit

struct CategoryIconPicker: View {
    @Binding var selectedIcon: String?
    let categoryName: String
    let isParent: Bool
    @Environment(\.dismiss) private var dismiss

    /// Icon ACTUALLY used (custom if set, otherwise the automatic fallback on the name).
    private var effectiveIcon: String {
        Category(id: 0, name: categoryName, parentId: isParent ? nil : 1, icon: selectedIcon).displayIcon
    }

    /// Search filter in the catalog (and free-text entry of an SF Symbol name).
    @State private var searchText = ""

    /// Whether an SF Symbol exists on the current OS. Lets us (a) accept
    /// free-text entry of ANY of the thousands of Apple symbols without
    /// bundling the full list, and (b) filter the catalog to never
    /// show an empty box if a symbol doesn't exist on this OS version.
    nonisolated private static func symbolExists(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        #if os(macOS)
        return NSImage(systemSymbolName: clean, accessibilityDescription: nil) != nil
        #else
        return UIKit.UIImage(systemName: clean) != nil
        #endif
    }

    /// The raw catalog, substantially expanded (~230 symbols) and themed.
    /// It does NOT claim to cover the 5000+ SF Symbols: free-text entry at the
    /// top of the sheet gives access to everything else.
    private static let rawGroups: [(title: String, icons: [String])] = [
        ("Alimentation", ["cart.fill", "basket.fill", "fork.knife", "cup.and.saucer.fill", "mug.fill",
                          "wineglass.fill", "birthday.cake.fill", "fish.fill", "carrot.fill",
                          "takeoutbag.and.cup.and.straw.fill", "popcorn.fill", "leaf.fill", "flame.fill"]),
        ("Transport",    ["car.fill", "car.2.fill", "bolt.car.fill", "tram.fill", "bus.fill", "ferry.fill",
                          "fuelpump.fill", "airplane", "bicycle", "scooter", "figure.walk", "parkingsign",
                          "road.lanes", "truck.box.fill", "train.side.front.car"]),
        ("Logement",     ["house.fill", "house.lodge.fill", "building.2.fill", "key.fill", "bolt.fill",
                          "wifi", "lightbulb.fill", "wrench.and.screwdriver.fill", "bed.double.fill",
                          "sofa.fill", "shower.fill", "spigot.fill", "washer.fill", "chair.fill",
                          "lamp.floor.fill", "hammer.fill", "paintbrush.fill"]),
        ("Santé",        ["heart.fill", "stethoscope", "pills.fill", "cross.fill", "cross.case.fill",
                          "bandage.fill", "syringe.fill", "eye.fill", "ear.fill", "brain.head.profile",
                          "lungs.fill", "tooth.fill", "waveform.path.ecg", "facemask.fill"]),
        ("Loisirs",      ["gamecontroller.fill", "film.fill", "music.note", "headphones", "book.fill",
                          "photo.fill", "theatermasks.fill", "ticket.fill", "tv.fill", "guitars.fill",
                          "paintpalette.fill", "puzzlepiece.fill", "die.face.5.fill", "camera.fill",
                          "binoculars.fill", "party.popper.fill"]),
        ("Sport",        ["figure.run", "figure.hiking", "figure.pool.swim", "figure.outdoor.cycle",
                          "sportscourt.fill", "trophy.fill", "dumbbell.fill", "figure.yoga",
                          "figure.strengthtraining.traditional", "soccerball", "basketball.fill",
                          "tennis.racket", "figure.skiing.downhill", "medal.fill"]),
        ("Shopping",     ["bag.fill", "tag.fill", "gift.fill", "tshirt.fill", "watch.analog", "sparkles",
                          "shippingbox.fill", "cart.badge.plus", "handbag.fill", "eyeglasses",
                          "shoeprints.fill", "scissors", "comb.fill"]),
        ("Finance",      ["banknote.fill", "building.columns.fill", "chart.line.uptrend.xyaxis",
                          "chart.pie.fill", "chart.bar.fill", "arrow.uturn.left.circle.fill",
                          "creditcard.fill", "dollarsign.circle.fill", "eurosign.circle.fill", "percent",
                          "wallet.pass.fill", "signature", "doc.text.fill", "scalemass.fill",
                          "arrow.left.arrow.right", "bitcoinsign.circle.fill", "giftcard.fill"]),
        ("Travail",      ["briefcase.fill", "laptopcomputer", "desktopcomputer", "printer.fill",
                          "person.2.fill", "person.crop.circle.fill", "calendar", "clock.fill",
                          "envelope.fill", "phone.fill", "folder.fill", "tray.full.fill",
                          "pencil.and.ruler.fill", "chart.xyaxis.line", "network"]),
        ("Éducation",    ["graduationcap.fill", "book.closed.fill", "books.vertical.fill", "pencil",
                          "highlighter", "text.book.closed.fill", "globe.europe.africa.fill",
                          "function", "atom", "testtube.2", "backpack.fill", "ruler.fill"]),
        ("Famille",      ["figure.2.and.child.holdinghands", "figure.and.child.holdinghands",
                          "person.3.fill", "heart.circle.fill", "pawprint.fill", "dog.fill", "cat.fill",
                          "stroller.fill", "teddybear.fill", "balloon.2.fill", "hands.clap.fill"]),
        ("Voyage",       ["suitcase.fill", "beach.umbrella.fill", "map.fill", "mappin.and.ellipse",
                          "globe", "tent.fill", "mountain.2.fill", "sun.max.fill", "snowflake",
                          "camera.viewfinder", "passport", "signpost.right.fill"]),
        ("Technologie",  ["iphone", "ipad", "applewatch", "airpods.gen3", "display", "externaldrive.fill",
                          "internaldrive.fill", "server.rack", "antenna.radiowaves.left.and.right",
                          "cloud.fill", "lock.fill", "shield.fill", "cpu.fill", "battery.100percent",
                          "cable.connector", "gearshape.fill"]),
        ("Nature",       ["leaf.fill", "tree.fill", "drop.fill", "flame.fill", "wind", "cloud.rain.fill",
                          "moon.stars.fill", "sunrise.fill", "water.waves", "bird.fill", "ant.fill",
                          "camera.macro", "globe.americas.fill"]),
        ("Divers",       ["star.fill", "bell.fill", "paperclip", "ellipsis.circle.fill",
                          "questionmark.circle.fill", "folder.fill", "repeat", "flag.fill",
                          "bookmark.fill", "checkmark.seal.fill", "exclamationmark.triangle.fill",
                          "trash.fill", "archivebox.fill", "square.grid.2x2.fill", "circle.hexagongrid.fill",
                          "infinity", "number"]),
    ]

    /// Effective catalog: symbols actually available on this OS (computed
    /// once). Avoids empty boxes if a symbol was introduced in
    /// an iOS/macOS version more recent than the device's.
    private static let groups: [(title: String, icons: [String])] = rawGroups
        .map { (title: $0.title, icons: $0.icons.filter(symbolExists)) }
        .filter { !$0.icons.isEmpty }

    /// Catalog filtered by the search (on the symbol's name AND its theme).
    private var filteredGroups: [(title: String, icons: [String])] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Self.groups }
        return Self.groups
            .map { group in
                group.title.lowercased().contains(q)
                    ? group
                    : (title: group.title, icons: group.icons.filter { $0.lowercased().contains(q) })
            }
            .filter { !$0.icons.isEmpty }
    }

    /// An SF Symbol name typed by hand, valid but absent from the catalog → offered
    /// as-is. This is what opens access to the thousands of Apple symbols.
    private var customSymbolCandidate: String? {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, Self.symbolExists(q) else { return nil }
        let alreadyListed = filteredGroups.contains { $0.icons.contains(q) }
        return alreadyListed ? nil : q
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current selection — ALWAYS shows the icon actually used (custom
            // or automatic fallback), not a generic tag.fill.
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: effectiveIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedIcon == nil ? "Icône automatique" : "Icône personnalisée")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text(effectiveIcon)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if selectedIcon == nil {
                        Text("Calculée depuis le nom « \(categoryName) »")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    }
                }
                Spacer()
                if selectedIcon != nil {
                    Button {
                        selectedIcon = nil
                    } label: {
                        Label("Auto", systemImage: "wand.and.stars")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)

            Divider()

            // Search within the catalog + free-text entry of an SF Symbol name.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    TextField("Rechercher une icône (ex. « car », « heart »)", text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.callout)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(AppTheme.Colors.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                Text("Tape le nom exact d'un SF Symbol pour utiliser n'importe quelle icône Apple.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
            }

            // A symbol typed by hand, valid and outside the catalog → usable directly.
            if let custom = customSymbolCandidate {
                Button {
                    selectedIcon = custom
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: custom)
                            .font(.system(size: 18))
                            .foregroundStyle(AppTheme.Colors.accent)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.Colors.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Utiliser « \(custom) »")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text("Symbole SF valide")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    .padding(8)
                    .background(AppTheme.Colors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            // No results AND unrecognized entry → an explicit message.
            if filteredGroups.isEmpty && customSymbolCandidate == nil && !searchText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("Aucune icône trouvée. « \(searchText) » n'est pas un SF Symbol connu.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            }

            // Icon grid grouped by theme
            ForEach(filteredGroups, id: \.title) { group in
                Text(LocalizedStringKey(group.title))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.top, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(group.icons, id: \.self) { icon in
                        Button {
                            selectedIcon = icon
                            dismiss()
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedIcon == icon
                                          ? AppTheme.Colors.accent.opacity(0.25)
                                          : AppTheme.Colors.textPrimary.opacity(0.06))
                                Image(systemName: icon)
                                    .font(.system(size: 16))
                                    .foregroundStyle(selectedIcon == icon ? AppTheme.Colors.accent : AppTheme.Colors.textPrimary)
                            }
                            .frame(height: 38)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selectedIcon == icon ? AppTheme.Colors.accent : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
