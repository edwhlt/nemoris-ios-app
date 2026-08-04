#!/bin/zsh
# Tests unitaires BankStatementExtractor — compile les fichiers RÉELS des
# moteurs avec le harness et exécute. Aucune dépendance Xcode/XCTest :
# `./run_bank_statement_tests.sh`
#
# `InvestmentStatementExtractor` est compilé aussi : le moteur bancaire
# réutilise ses primitives pures (firstDate, parseNumber) plutôt que d'en
# dupliquer une seconde version qui divergerait.
#
# À lancer après toute modification de l'extraction déterministe de relevés.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Investments/Service/PDFImport/InvestmentStatementExtractor.swift \
  ../Nemoris/Features/Import/Service/BankStatementExtractor.swift \
  BankStatementExtractorTests.swift \
  -o "$BUILD/bank_statement_tests"

"$BUILD/bank_statement_tests"
