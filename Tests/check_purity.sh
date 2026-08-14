#!/bin/zsh
# Garde-fou de pureté des moteurs.
#
# Un « moteur pur » ne dépend que de Foundation : il reçoit ses entrées en
# paramètres au lieu d'aller les chercher dans une base, sur le réseau ou dans
# l'écran. C'est ce qui le rend testable et raisonnable.
#
# Cette vérification remplace un effet de bord des harnais `swiftc`, qui
# compilent ces fichiers SEULS et cassent donc dès qu'un import interdit
# apparaît. XCTest, lui, compile l'application entière et ne le verrait pas :
# sans ce script, supprimer les harnais ferait disparaître le garde-fou avec.
set -e
cd "$(dirname "$0")/.."

INTERDITS="SwiftUI|UIKit|AppKit|PDFKit|Vision|FoundationModels|CloudKit|Contacts|WidgetKit|PhotosUI|MapKit|StoreKit|SQLite3"

MOTEURS=(
  "Nemoris/Features/Budget/Service/EnvelopeSpendingCalculator.swift"
  "Nemoris/Features/Dashboard/Service/DashboardSnapshot.swift"
  "Nemoris/Features/Dashboard/Service/Layout/DashboardGridPlanner.swift"
  "Nemoris/Features/Dashboard/Model/DashboardCardID.swift"
  "Nemoris/Features/Dashboard/Model/DashboardLayoutStore.swift"
  "Nemoris/Features/Enrichment/Service/AIFeature.swift"
  "Nemoris/Features/Import/Service/BankStatementExtractor.swift"
  "Nemoris/Features/Import/Pipeline/ImportElement.swift"
  "Nemoris/Features/Import/Pipeline/ImportFormatSniffer.swift"
  "Nemoris/Features/Import/Pipeline/LenientJSON.swift"
  "Nemoris/Features/Import/Pipeline/Readers/LedgerXMLReader.swift"
  "Nemoris/Features/Import/Pipeline/Readers/XLSXReader.swift"
  "Nemoris/Features/Import/Pipeline/Readers/ZIPArchiveReader.swift"
  "Nemoris/Features/Investments/Service/PortfolioEvolutionBuilder.swift"
  "Nemoris/Features/Investments/Service/PDFImport/InvestmentStatementExtractor.swift"
  "Nemoris/Features/Investments/Service/PDFImport/StatementReconciler.swift"
  "Nemoris/Features/Patrimoine/Service/PatrimoineSnapshotBuilder.swift"
)
# Le module de planification de requêtes est pur dans son intégralité.
MOTEURS+=("Nemoris/Features/Enrichment/Service/QueryPlanning/"*.swift)

echec=0
for f in "${MOTEURS[@]}"; do
  [[ -f "$f" ]] || { echo "❌ moteur introuvable : $f"; echec=1; continue; }
  trouves=$(grep -nE "^import ($INTERDITS)\b" "$f" || true)
  if [[ -n "$trouves" ]]; then
    echo "❌ $f"
    echo "$trouves" | sed 's/^/      /'
    echec=1
  fi
done

if [[ $echec -eq 0 ]]; then
  echo "✅ ${#MOTEURS[@]} moteurs purs — aucun import interdit"
else
  echo ""
  echo "Un moteur pur ne doit dépendre que de Foundation. Si la dépendance est"
  echo "réellement nécessaire, elle appartient à l'appelant : passe le résultat"
  echo "en paramètre plutôt que d'aller le chercher depuis le moteur."
  exit 1
fi
