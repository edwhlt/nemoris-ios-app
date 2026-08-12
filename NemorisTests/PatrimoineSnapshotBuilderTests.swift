import Foundation
import Testing
@testable import Nemoris

/// Résolution de la valeur des actifs et agrégation du patrimoine.
///
/// L'enjeu central de ce moteur tient en une phrase de sa propre
/// documentation : un solde à zéro ne permet pas de distinguer un compte
/// supprimé d'un compte bien vivant mais vide. Confondre les deux fait
/// disparaître un actif du patrimoine sans le moindre signal.
@Suite("PatrimoineSnapshotBuilder")
struct PatrimoineSnapshotBuilderTests {

    private func actif(id: Int, compte: Int? = nil, investissement: Int? = nil,
                       manuel: Double = 0, dernierConnu: Double = 0) -> PatrimoineAsset {
        PatrimoineAsset(id: id, name: "Actif \(id)", assetKind: .savings,
                        linkedAccountId: compte, linkedInvestmentAccountId: investissement,
                        manualValue: manuel, lastKnownValue: dernierConnu,
                        notes: nil, createdAt: date("2026-01-01"))
    }

    private func compteInvestissement(id: Int, valeur: Double, cash: Double = 0) -> InvestmentAccount {
        InvestmentAccount(id: id, name: "PEA", broker: "Courtier", currency: "EUR",
                          accountType: "PEA", currentValue: valeur, investedAmount: 0,
                          openedAt: date("2026-01-01"), cashBalance: cash)
    }

    // MARK: - La distinction qui compte

    @Test("Un compte vivant à solde nul rend zéro, pas la dernière valeur connue")
    func compteVivantASoldeNul() {
        // Le compte existe et vaut réellement 0 : c'est la vérité, il faut
        // l'afficher. Retomber sur lastKnownValue mentirait sur le patrimoine.
        let (valeur, source) = PatrimoineSnapshotBuilder.resolveValue(
            for: actif(id: 1, compte: 10, dernierConnu: 5_000),
            existingBankAccountIds: [10],
            bankBalances: [10: 0],
            investmentAccounts: [])

        #expect(valeur == 0, "valeur : \(valeur)")
        #expect(source == .linkedAccount)
    }

    @Test("Un compte supprimé retombe sur la dernière valeur connue et se signale")
    func compteSupprime() {
        // Même solde absent, mais le compte n'existe plus. Afficher 0 ferait
        // disparaître l'actif du patrimoine sans que l'utilisateur comprenne.
        let (valeur, source) = PatrimoineSnapshotBuilder.resolveValue(
            for: actif(id: 1, compte: 10, dernierConnu: 5_000),
            existingBankAccountIds: [],
            bankBalances: [:],
            investmentAccounts: [])

        #expect(valeur == 5_000, "valeur : \(valeur)")
        #expect(source == .brokenLink, "le lien rompu doit être signalé pour l'alerte UI")
    }

    @Test("Un compte existant mais sans solde fetché garde la dernière valeur connue")
    func soldeNonFetche() {
        // Le compte existe, mais son solde n'a pas été chargé. Ce n'est pas un
        // lien rompu — on ne doit pas alerter — mais on ne connaît pas la valeur.
        let (valeur, source) = PatrimoineSnapshotBuilder.resolveValue(
            for: actif(id: 1, compte: 10, dernierConnu: 3_200),
            existingBankAccountIds: [10],
            bankBalances: [:],
            investmentAccounts: [])

        #expect(valeur == 3_200)
        #expect(source == .linkedAccount, "pas d'alerte de lien rompu sur un compte vivant")
    }

    // MARK: - Autres sources

    @Test("Un actif sans lien prend sa valeur saisie à la main")
    func actifManuel() {
        let (valeur, source) = PatrimoineSnapshotBuilder.resolveValue(
            for: actif(id: 1, manuel: 1_500, dernierConnu: 999),
            existingBankAccountIds: [], bankBalances: [:], investmentAccounts: [])

        #expect(valeur == 1_500, "la valeur manuelle prime sur la dernière connue")
        #expect(source == .manual)
    }

    @Test("Un compte-titres additionne ses positions et ses liquidités")
    func compteTitres() {
        // Oublier le cash sous-évaluerait le patrimoine du montant non investi.
        let (valeur, source) = PatrimoineSnapshotBuilder.resolveValue(
            for: actif(id: 1, investissement: 7),
            existingBankAccountIds: [], bankBalances: [:],
            investmentAccounts: [compteInvestissement(id: 7, valeur: 12_000, cash: 800)])

        #expect(valeur == 12_800, "valeur : \(valeur)")
        #expect(source == .linkedInvestment)
    }

    @Test("Un compte-titres disparu se signale comme lien rompu")
    func compteTitresSupprime() {
        let (valeur, source) = PatrimoineSnapshotBuilder.resolveValue(
            for: actif(id: 1, investissement: 7, dernierConnu: 9_000),
            existingBankAccountIds: [], bankBalances: [:], investmentAccounts: [])

        #expect(valeur == 9_000)
        #expect(source == .brokenLink)
    }

    @Test("Le lien bancaire prime sur le lien d'investissement")
    func prioriteDesLiens() {
        // Cas de saisie incohérente : les deux liens sont renseignés. L'ordre de
        // priorité doit être stable, sinon la valeur affichée change au hasard.
        let (valeur, source) = PatrimoineSnapshotBuilder.resolveValue(
            for: actif(id: 1, compte: 10, investissement: 7),
            existingBankAccountIds: [10], bankBalances: [10: 4_000],
            investmentAccounts: [compteInvestissement(id: 7, valeur: 50_000)])

        #expect(valeur == 4_000, "valeur : \(valeur)")
        #expect(source == .linkedAccount)
    }

    // MARK: - Résolution en lot

    @Test("La résolution en lot traite chaque actif selon sa propre source")
    func resolutionEnLot() {
        let actifs = [actif(id: 1, compte: 10, dernierConnu: 100),
                      actif(id: 2, investissement: 7),
                      actif(id: 3, manuel: 250),
                      actif(id: 4, compte: 99, dernierConnu: 400)]

        let (valeurs, sources) = PatrimoineSnapshotBuilder.resolveValues(
            assets: actifs, existingBankAccountIds: [10], bankBalances: [10: 1_000],
            investmentAccounts: [compteInvestissement(id: 7, valeur: 2_000)])

        #expect(valeurs[1] == 1_000); #expect(sources[1] == .linkedAccount)
        #expect(valeurs[2] == 2_000); #expect(sources[2] == .linkedInvestment)
        #expect(valeurs[3] == 250);   #expect(sources[3] == .manual)
        #expect(valeurs[4] == 400);   #expect(sources[4] == .brokenLink)
    }

    @Test("Les identifiants de comptes liés sont extraits sans doublon")
    func comptesLies() {
        let ids = PatrimoineSnapshotBuilder.linkedBankAccountIds(in: [
            actif(id: 1, compte: 10), actif(id: 2, compte: 10),
            actif(id: 3, compte: 20), actif(id: 4)])

        #expect(ids == [10, 20], "obtenu : \(ids.sorted())")
    }

    // MARK: - Agrégation

    @Test("Un actif non résolu ne disparaît pas silencieusement du total")
    func filetDeSecurite() {
        // Le filet documenté : si un actif n'a pas été résolu, on prend sa
        // dernière valeur connue plutôt que de l'omettre. Une ligne manquante
        // dans un patrimoine ne se remarque pas.
        let total = PatrimoineSnapshotBuilder.totalAssetsValue(
            assets: [actif(id: 1, dernierConnu: 300), actif(id: 2, dernierConnu: 700)],
            resolvedValues: [1: 500])

        #expect(total == 1_200, "500 résolu + 700 de filet, obtenu : \(total)")
    }

    @Test("Un prêt sans état calculé compte pour son capital initial")
    func filetSurLesPrets() {
        let pret = PatrimoineLoan(id: 1, name: "Crédit", loanType: .amortizing,
                                  principal: 100_000, annualRate: 0.03, durationMonths: 240,
                                  deferralMonths: 0, startDate: date("2026-01-01"),
                                  insuranceMonthly: 0, linkedRealEstateId: nil,
                                  notes: nil, createdAt: date("2026-01-01"))

        // Sans état, on ne minimise pas la dette : on prend le principal.
        #expect(PatrimoineSnapshotBuilder.totalLiabilities(loans: [pret], loanStates: [:]) == 100_000)
    }

    @Test("Le snapshot agrège actifs, immobilier et dettes de façon cohérente")
    func agregationComplete() {
        let bien = PatrimoineRealEstate(id: 1, name: "Studio", purchasePrice: 150_000,
                                        purchaseDate: date("2024-01-01"), currentValue: 180_000,
                                        estimatedAt: nil, address: nil, notes: nil,
                                        createdAt: date("2024-01-01"))
        let pret = PatrimoineLoan(id: 1, name: "Crédit", loanType: .amortizing,
                                  principal: 120_000, annualRate: 0.03, durationMonths: 240,
                                  deferralMonths: 0, startDate: date("2024-01-01"),
                                  insuranceMonthly: 0, linkedRealEstateId: 1,
                                  notes: nil, createdAt: date("2024-01-01"))

        let snap = PatrimoineSnapshotBuilder.snapshot(
            assets: [actif(id: 1, manuel: 20_000)],
            realEstates: [bien], loans: [pret],
            resolvedValues: [1: 20_000], loanStates: [:])

        #expect(snap.totalAssets == 200_000, "20 000 de liquide + 180 000 d'immobilier")
        #expect(snap.totalLiabilities == 120_000)
        #expect(snap.netWorth == 80_000)
        #expect(snap.assetsCount == 1)
        #expect(snap.realEstateCount == 1)
        #expect(snap.loansCount == 1)
    }

    @Test("Un patrimoine vide s'agrège à zéro sans dériver")
    func patrimoineVide() {
        let snap = PatrimoineSnapshotBuilder.snapshot(
            assets: [], realEstates: [], loans: [], resolvedValues: [:], loanStates: [:])

        #expect(snap.totalAssets == 0)
        #expect(snap.totalLiabilities == 0)
        #expect(snap.netWorth == 0)
        #expect(!snap.hasData, "sans aucun élément, l'écran doit proposer l'état vide")
    }
}
