#!/bin/zsh
# Vérification RÉSEAU des contrats d'API de la recherche avancée (AXE S).
# ~25 requêtes, ~10 s. À lancer À LA MAIN avant une release, pas dans le flux habituel.
#
#   NEMORIS_LIVE_TESTS=1 ./run_sirene_live_check.sh
#
# Trois raisons pour lesquelles ce script est HORS du chemin de test par défaut :
#   1. il vit dans `integration/`, qu'aucun glob `Tests/run_*.sh` n'attrape ;
#   2. il refuse de tourner sans NEMORIS_LIVE_TESTS=1, et SORT AVEC 0 dans ce cas —
#      être sauté n'est jamais un échec ;
#   3. un échec y signifie le plus souvent « gouv.fr est indisponible », pas « le code
#      est cassé ». La logique, elle, est couverte hors ligne par
#      run_query_planner_tests.sh et run_merchant_corpus_tests.sh.
#
# Ce qu'il vérifie : que `minimal=true` reste exigé avant `include`, que
# `matching_etablissements` renvoie bien SIRET + adresse par branche, que les filtres
# code_commune / departement / near_point fonctionnent, que geo.api.gouv.fr résout
# toujours les noms de communes TRONQUÉS par les relevés — et que le bug d'origine
# (« q=carrefour market flanches » → 0) se comporte comme documenté.
set -e
cd "$(dirname "$0")"

if [[ "$NEMORIS_LIVE_TESTS" != "1" ]]; then
  echo "⏭  Ce script sort sur le réseau (recherche-entreprises.api.gouv.fr + geo.api.gouv.fr)."
  echo "   Relance avec : NEMORIS_LIVE_TESTS=1 ./run_sirene_live_check.sh"
  exit 0
fi

BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

# `-parse-as-library` : sur un fichier UNIQUE, swiftc le traiterait sinon comme un script
# à code de haut niveau, ce qui interdit `@main`. Les autres harnesses compilent plusieurs
# fichiers et n'en ont pas besoin.
echo "══ Contrats d'API ══"
xcrun swiftc -parse-as-library SireneLiveCheck.swift -o "$BUILD/sirene_live_check"
"$BUILD/sirene_live_check"

# Second volet : la chaîne de production complète, avec les fichiers RÉELS de l'app.
# C'est ce qui prouve que ce que l'utilisateur verra à l'écran est correct — l'UI ne fait
# qu'afficher le `MerchantSearchResult` produit ici.
echo
echo "══ Chaîne complète (fichiers réels de l'app) ══"
xcrun swiftc \
  ../../Nemoris/Features/Investments/Service/MarketDataReliability.swift \
  ../../Nemoris/Features/Enrichment/Model/EnrichmentModels.swift \
  ../../Nemoris/Features/Enrichment/Model/CompanyDataSources/Sirene/SireneModels.swift \
  ../../Nemoris/Features/Enrichment/Service/CompanyDataSources/Sirene/CompanyRegistryClient.swift \
  ../../Nemoris/Features/Enrichment/Model/CompanyDataSources/CompanyMatchModels.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/MerchantQueryPlan.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/SearchBudget.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/LocalityResolver.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/MerchantTokenSimilarity.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/AbbreviationTable.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/ForeignLocalityTable.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/BankLabelTemplate.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/LLMQueryRefinement.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/DeterministicQueryRefiner.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/MerchantQueryPlanner.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/CandidateRanker.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/GeoCommuneResolver.swift \
  ../../Nemoris/Features/Enrichment/Service/QueryPlanning/MerchantQueryExecutor.swift \
  ExecutorLiveCheck.swift \
  -o "$BUILD/executor_live_check"
"$BUILD/executor_live_check"
