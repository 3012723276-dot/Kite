#!/usr/bin/env bash
set -euo pipefail

if ! command -v android >/dev/null 2>&1; then
  echo "::error::Android CLI is not available on PATH"
  exit 1
fi

# Android CLI uses slash-separated package paths. Feed enough affirmative
# answers for first-time license prompts while keeping the command suitable
# for non-interactive CI runners.
printf 'y\n%.0s' {1..100} | android --no-metrics sdk install \
  platform-tools \
  platforms/android-36 \
  build-tools/36.0.0 \
  ndk/29.0.14206865

echo "ANDROID_NDK_HOME=$ANDROID_HOME/ndk/29.0.14206865" >> "$GITHUB_ENV"
echo "ANDROID_NDK_ROOT=$ANDROID_HOME/ndk/29.0.14206865" >> "$GITHUB_ENV"
