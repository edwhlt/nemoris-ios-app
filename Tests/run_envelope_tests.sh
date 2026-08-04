#!/bin/zsh
# Tests unitaires EnvelopeSpendingCalculator — compile les fichiers RÉELS du
# moteur avec le harness et exécute. Aucune dépendance Xcode/XCTest :
# `./run_envelope_tests.sh`
#
# À lancer après TOUTE modification du calcul "dépensé par enveloppe" : il est
# partagé par le module Budget, le Dashboard, l'AlertEngine et le widget.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Budget/BudgetModels.swift \
  ../Nemoris/Features/Budget/EnvelopeSpendingCalculator.swift \
  EnvelopeSpendingTests.swift \
  -o "$BUILD/envelope_tests"

"$BUILD/envelope_tests"
