#!/bin/zsh
# Tests unitaires de la couche de planification de requêtes (AXE S) — compile les fichiers
# RÉELS du moteur avec le harness et exécute. Aucune dépendance Xcode/XCTest :
# `./run_query_planner_tests.sh`
#
# À lancer après TOUTE modification de MerchantQueryPlanner / BankLabelTemplate /
# CandidateRanker / DeterministicQueryRefiner / MerchantTokenSimilarity.
#
# Verrouille en particulier le bug d'origine : la ville ne doit JAMAIS finir dans le `q=`
# envoyé au registre d'entreprises (« q=carrefour market flanches » → 0 résultat,
# « q=carrefour market » → 1907).
#
# Ce script est AUSSI le garde-fou de pureté du module : les fichiers ci-dessous ne doivent
# importer que Foundation. Un import de NemorisEngine / MapKit / FoundationModels / SwiftUI
# casse cette compilation, et c'est voulu.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Enrichment/QueryPlanning/MerchantQueryPlan.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/SearchBudget.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/LocalityResolver.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/MerchantTokenSimilarity.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/AbbreviationTable.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/ForeignLocalityTable.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/BankLabelTemplate.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/LLMQueryRefinement.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/DeterministicQueryRefiner.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/MerchantQueryPlanner.swift \
  ../Nemoris/Features/Enrichment/QueryPlanning/CandidateRanker.swift \
  MerchantQueryPlannerTests.swift \
  -o "$BUILD/query_planner_tests"

"$BUILD/query_planner_tests"
