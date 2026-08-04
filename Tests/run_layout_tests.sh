#!/bin/zsh
# Tests unitaires du registre de cartes du Dashboard, de sa persistance et du
# planificateur de grille. Compile les fichiers RÉELS, sans Xcode/XCTest :
# `./run_layout_tests.sh`
#
# À lancer après tout ajout/retrait de carte dans `DashboardCardID` ou toute
# modification de `DashboardLayoutStore.sanitize`.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Features/Dashboard/Service/DashboardSnapshot.swift \
  ../Nemoris/Features/Dashboard/Model/DashboardCardID.swift \
  ../Nemoris/Features/Dashboard/Model/DashboardLayoutStore.swift \
  ../Nemoris/Features/Dashboard/Layout/DashboardGridPlanner.swift \
  DashboardLayoutTests.swift \
  -o "$BUILD/layout_tests"

"$BUILD/layout_tests"
