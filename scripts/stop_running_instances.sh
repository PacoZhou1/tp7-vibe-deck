#!/bin/zsh
set -u

APP_NAME="Open Speech ASR"
EXECUTABLE_NAME="OpenSpeechASR"

echo "Stopping running ${APP_NAME} instances..."

terminate_matching_processes() {
    local pattern="$1"
    local signal="${2:-TERM}"
    pgrep -f "${pattern}" 2>/dev/null | while read -r pid; do
        if [[ -n "${pid}" && "${pid}" != "$$" ]]; then
            kill "-${signal}" "${pid}" 2>/dev/null || true
        fi
    done
}

pkill -x "${APP_NAME}" 2>/dev/null || true
pkill -x "${EXECUTABLE_NAME}" 2>/dev/null || true

terminate_matching_processes "${APP_NAME}.app/Contents/MacOS/${EXECUTABLE_NAME}"
terminate_matching_processes "Contents/Resources/backend/${APP_NAME}"
terminate_matching_processes "Contents/Resources/backend/.*/inference_server.py"
terminate_matching_processes "openspeech-dev/backend/.*/inference_server.py"

sleep 1

terminate_matching_processes "${APP_NAME}.app/Contents/MacOS/${EXECUTABLE_NAME}" KILL
terminate_matching_processes "Contents/Resources/backend/${APP_NAME}" KILL
terminate_matching_processes "Contents/Resources/backend/.*/inference_server.py" KILL
terminate_matching_processes "openspeech-dev/backend/.*/inference_server.py" KILL

echo "Running ${APP_NAME} instances stopped."
