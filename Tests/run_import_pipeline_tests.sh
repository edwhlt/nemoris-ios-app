#!/bin/zsh
# Tests unitaires du pipeline d'import unifié — compile les fichiers RÉELS des
# moteurs avec le harness et exécute. Aucune dépendance Xcode/XCTest :
# `./run_import_pipeline_tests.sh`
#
# Couvre : sniffing du format par les octets, lecture ZIP, classeur XLSX,
# relevés CAMT.053 et OFX/QFX, modèle d'échange `ImportElement`, table commune
# CSV/classeur.
#
# ⚠️ Ce script EST le garde-fou de pureté du pipeline : aucun des fichiers
# listés ci-dessous ne peut importer PDFKit, Vision, FoundationModels ni SwiftUI
# sans casser la compilation. Si un jour l'un d'eux en a besoin, c'est le signe
# qu'il faut extraire sa partie pure plutôt que d'assouplir ce harnais.
#
# À lancer après toute modification du pipeline d'import.
#
# La fixture `Fixtures/statement_fixture.xlsx` est régénérable par
# `python3 Fixtures/build_xlsx_fixture.py`.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Import/Service/BankStatementExtractor.swift \
  ../Nemoris/Features/Investments/Service/PDFImport/InvestmentStatementExtractor.swift \
  ../Nemoris/Features/Import/Model/ImportSessionModels.swift \
  ../Nemoris/Features/Import/Pipeline/ImportGrid.swift \
  ../Nemoris/Features/Import/Pipeline/ImportElement.swift \
  ../Nemoris/Features/Import/Pipeline/ImportFormatSniffer.swift \
  ../Nemoris/Features/Import/Pipeline/LenientJSON.swift \
  ../Nemoris/Features/Import/Pipeline/Readers/ZIPArchiveReader.swift \
  ../Nemoris/Features/Import/Pipeline/Readers/XLSXReader.swift \
  ../Nemoris/Features/Import/Pipeline/Readers/LedgerXMLReader.swift \
  ../Nemoris/Features/Import/Service/CSVParserV3.swift \
  ImportPipelineTests.swift \
  -o "$BUILD/import_pipeline_tests"

"$BUILD/import_pipeline_tests"
