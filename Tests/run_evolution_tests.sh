#!/bin/zsh
# Tests unitaires PortfolioEvolutionBuilder — compile le fichier RÉEL du moteur
# avec le harness et exécute. Aucune dépendance Xcode/XCTest :
# `./run_evolution_tests.sh`
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Investments/Service/PortfolioEvolutionBuilder.swift \
  PortfolioEvolutionTests.swift \
  -o "$BUILD/evolution_tests"

"$BUILD/evolution_tests"
