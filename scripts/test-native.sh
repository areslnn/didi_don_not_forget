#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}/.."
mkdir -p build/tests build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  src/native/RelayModels.swift tests/RelayModelsTests.swift -o build/tests/relay-model-tests
build/tests/relay-model-tests
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  src/native/RelayModels.swift src/native/RelayAPIClient.swift tests/RelayAPIClientTests.swift \
  -o build/tests/relay-api-tests
build/tests/relay-api-tests
