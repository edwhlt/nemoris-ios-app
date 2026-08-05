#!/bin/zsh
# Tests de la RÈGLE de choix du backend IA par fonctionnalité — compile le
# fichier RÉEL du moteur avec le harness et exécute. Aucune dépendance
# Xcode/XCTest : `./run_ai_backend_tests.sh`
#
# ⚠️ Ce script EST le garde-fou de pureté d'`AIFeature.swift` : il ne peut pas
# importer FoundationModels ni SwiftUI sans casser la compilation. C'est ce qui
# garantit que la règle reste testable, là où l'état réel de l'appareil (Apple
# Intelligence disponible ? clé en trousseau ?) ne l'est pas — cet état est
# fourni en paramètre à `AIBackendResolver`.
#
# À lancer après toute modification d'`AIFeature` / `AIBackendResolver`.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Enrichment/Service/AIFeature.swift \
  AIBackendTests.swift \
  -o "$BUILD/ai_backend_tests"

"$BUILD/ai_backend_tests"
