#!/bin/zsh
# Tests unitaires SyncPayloadStore — compile les fichiers RÉELS du store avec
# le harness et exécute. Aucune dépendance Xcode/XCTest : `./run_sync_tests.sh`.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap "rm -rf $BUILD" EXIT

xcrun swiftc \
  ../Nemoris/Data/Database/SyncSchema.swift \
  ../Nemoris/Data/Sync/SyncPayloadStore.swift \
  SyncStoreTests.swift \
  -o "$BUILD/syncstore_tests"

"$BUILD/syncstore_tests"
