#!/usr/bin/env bash
set -euo pipefail

# The source handoff intentionally omits the binary Gradle wrapper JAR.
# CI images provide Gradle; generate the standard wrapper before Flutter invokes it.
if [[ ! -f android/gradlew || ! -f android/gradle/wrapper/gradle-wrapper.jar ]]; then
  command -v gradle >/dev/null 2>&1 || {
    echo "Gradle is missing; install Gradle 8.9 or use the supplied Codemagic/GitHub CI workflow."
    exit 1
  }
  (cd android && gradle wrapper --gradle-version 8.9)
fi
chmod +x android/gradlew
