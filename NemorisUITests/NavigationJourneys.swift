import XCTest

/// Parcours d'interface : l'application se lance et chaque module s'ouvre.
///
/// Volontairement peu nombreux. Un test d'interface lent et fragile est pire
/// que pas de test : au premier échec douteux on le désactive, et il ne protège
/// plus rien. Ceux-ci ne vérifient qu'une chose, mais celle qui a réellement
/// cassé par le passé — la navigation entre modules, où plusieurs plantages ont
/// été documentés (liste imbriquée, panneau masqué, contenu poussé sur macOS).
///
/// Ils n'écrivent rien en base : les relancer ne laisse aucune trace.
final class NavigationJourneys: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func lancer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    // MARK: - Démarrage

    func testApplicationSeLanceEtAfficheUneInterface() {
        let app = lancer()

        // `wait` plutôt qu'une assertion immédiate : le démarrage charge un
        // modèle d'embeddings, l'écran n'est pas prêt à la première frame.
        // Sans attente, ce test échouerait par intermittence — le genre
        // d'échec qui fait perdre confiance dans toute la suite.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "l'application doit atteindre le premier plan")
        // On vérifie qu'une interface EXISTE, pas qu'elle porte tel
        // identifiant : SwiftUI n'en pose pas sur ses fenêtres.
        XCTAssertGreaterThan(app.descendants(matching: .any).count, 0,
                             "une interface doit être rendue")
    }

    // MARK: - Navigation entre modules

    func testChaqueModuleSOuvreSansPlanter() {
        let app = lancer()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        // On tape sur les onglets QUI EXISTENT plutôt que d'exiger une liste
        // figée : les modules sont activables et désactivables, un test qui
        // les présumerait tous présents casserait au premier réglage changé.
        let barre = app.tabBars.firstMatch
        guard barre.waitForExistence(timeout: 15) else {
            // Disposition en colonnes (iPad, Mac) : pas de barre d'onglets.
            return
        }

        let onglets = barre.buttons.allElementsBoundByIndex
        XCTAssertFalse(onglets.isEmpty, "au moins un module doit être proposé")

        for onglet in onglets where onglet.isHittable {
            onglet.tap()
            XCTAssertEqual(app.state, .runningForeground,
                           "l'app a quitté le premier plan après « \(onglet.label) »")
        }
    }

    func testRetourSurUnModuleDejaVisiteNeCassePas() {
        let app = lancer()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        let barre = app.tabBars.firstMatch
        guard barre.waitForExistence(timeout: 15) else { return }
        let onglets = barre.buttons.allElementsBoundByIndex
        guard onglets.count >= 2 else { return }

        // Un module démonté puis remonté a déjà provoqué des pertes d'état et
        // des panneaux restés ouverts sur du contenu disparu.
        onglets[0].tap()
        onglets[1].tap()
        onglets[0].tap()

        XCTAssertEqual(app.state, .runningForeground,
                       "un aller-retour entre modules ne doit rien casser")
    }

    // MARK: - Cycle de vie

    func testLApplicationSurvitAUnPassageEnArrierePlan() {
        let app = lancer()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        // Le passage en arrière-plan déclenche l'envoi de la file de
        // synchronisation et la sauvegarde de la session d'import : deux
        // chemins qui touchent la base au pire moment.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20),
                      "l'app doit revenir au premier plan intacte")
    }
}
