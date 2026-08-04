#!/bin/zsh
# Tests unitaires de la couche snapshot du Dashboard — compile le fichier RÉEL
# avec le harness et exécute. Aucune dépendance Xcode/XCTest :
# `./run_dashboard_tests.sh`
#
# À lancer après toute modification de `DashboardAggregate` (ajout d'un agrégat,
# changement de portée de cache) ou de `DashboardPeriod`.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Dashboard/Service/DashboardSnapshot.swift \
  DashboardSnapshotTests.swift \
  -o "$BUILD/dashboard_tests"

"$BUILD/dashboard_tests"
