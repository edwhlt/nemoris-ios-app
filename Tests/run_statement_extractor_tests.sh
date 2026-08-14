#!/bin/zsh
# Tests unitaires InvestmentStatementExtractor — compile le fichier RÉEL du
# moteur avec le harness et exécute. Aucune dépendance Xcode/XCTest :
# `./run_statement_extractor_tests.sh`
#
# À lancer après toute modification de l'extraction déterministe des relevés.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Investments/Service/PDFImport/InvestmentStatementExtractor.swift \
  ../Nemoris/Features/Investments/Service/PDFImport/StatementReconciler.swift \
  StatementExtractorTests.swift \
  -o "$BUILD/statement_tests"

"$BUILD/statement_tests"
