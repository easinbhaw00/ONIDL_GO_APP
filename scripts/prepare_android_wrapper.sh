#!/usr/bin/env bash
set -euo pipefail

echo "Preparing Gradle Wrapper 8.14.3"

if [[ ! -f android/gradlew || ! -f android/gradle/wrapper/gradle-wrapper.jar ]]; then
  command -v gradle >/dev/null 2>&1 || {
    echo "Gradle is missing."
    exit 1
  }

  (cd android && gradle wrapper --gradle-version 8.14.3 --distribution-type bin)
fi

chmod +x android/gradlew

echo "Gradle wrapper preparation completed."
