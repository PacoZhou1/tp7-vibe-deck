#!/bin/zsh
set -u

APP_NAME="Open Speech ASR"
BUNDLE_ID="com.openspeech.asr"

echo "Resetting local ${APP_NAME} state for first-run QA..."

"$(dirname "$0")/stop_running_instances.sh"

defaults delete "${BUNDLE_ID}" 2>/dev/null || true

rm -rf "${HOME}/Library/Application Support/${APP_NAME}"
rm -rf "${HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState"
rm -rf "${HOME}/Library/Containers/${BUNDLE_ID}"
rm -f "${HOME}/openspeech-server.log"

for service in Microphone Accessibility ScreenCapture ListenEvent AppleEvents; do
    tccutil reset "${service}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
done

echo "Local ${APP_NAME} state reset."
