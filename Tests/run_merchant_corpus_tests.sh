#!/bin/zsh
# Mesure du SPECTRE DE RECHERCHE (AXE S) — fait tourner le planificateur RÉEL sur un corpus
# de libellés bancaires authentiques (anonymisés) et vérifie que le score ne régresse pas.
#
#   ./run_merchant_corpus_tests.sh [plancher] [nb_libellés_min]
#
# Trois garde-fous INDÉPENDANTS :
#   1. plancher de score        — défaut ci-dessous, ajusté quand le moteur progresse
#   2. libellés tagués `regression` — un seul échec = échec total, sans franchise
#   3. taille minimale du corpus    — empêche d'« améliorer » le score en retirant les cas durs
#
# Le corpus se régénère depuis le CSV source par :
#   cd Fixtures && python3 build_corpus.py ../../../personal-libelle-example.csv merchant_labels_corpus.json
#
# ⚠️ Ce score mesure la QUALITÉ DE PLANIFICATION, pas le taux de réussite bout en bout
# (qui suppose la cascade réseau réelle + une relecture humaine).
set -e
cd "$(dirname "$0")"

# Score au 2026-07-30 : 87,5 % (861/984). Plancher volontairement sous le score courant
# pour absorber le bruit, jamais très en dessous.
#
# Le plafond réaliste de cette mesure est ≈ 88 % : le reste est de la connaissance
# SÉMANTIQUE que rien ne peut extraire du libellé. « SAS SISENS » est bien le traiteur de
# la cantine, « EARLY MAKERS GROUP » la raison sociale d'emlyon, « IDFM » le facturier de
# la RATP, « AMER SPORTS » le propriétaire de Salomon. Dans tous ces cas l'extraction est
# CORRECTE — c'est le nom d'affichage saisi par l'utilisateur qui diffère, et ce
# renommage est une étape ultérieure, pas un échec de planification.
MIN_SCORE=${1:-0.85}
MIN_LABELS=${2:-950}

BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Enrichment/QueryPlanning/MerchantQueryPlan.swift \
  ../Nemoris/Enrichment/QueryPlanning/SearchBudget.swift \
  ../Nemoris/Enrichment/QueryPlanning/LocalityResolver.swift \
  ../Nemoris/Enrichment/QueryPlanning/MerchantTokenSimilarity.swift \
  ../Nemoris/Enrichment/QueryPlanning/AbbreviationTable.swift \
  ../Nemoris/Enrichment/QueryPlanning/ForeignLocalityTable.swift \
  ../Nemoris/Enrichment/QueryPlanning/BankLabelTemplate.swift \
  ../Nemoris/Enrichment/QueryPlanning/LLMQueryRefinement.swift \
  ../Nemoris/Enrichment/QueryPlanning/DeterministicQueryRefiner.swift \
  ../Nemoris/Enrichment/QueryPlanning/MerchantQueryPlanner.swift \
  ../Nemoris/Enrichment/QueryPlanning/CandidateRanker.swift \
  MerchantCorpusTests.swift \
  -o "$BUILD/merchant_corpus_tests"

"$BUILD/merchant_corpus_tests" Fixtures/merchant_labels_corpus.json "$MIN_SCORE" "$MIN_LABELS"
