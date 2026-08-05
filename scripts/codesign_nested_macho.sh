#!/bin/zsh
set -euo pipefail

ROOT="${1:?Usage: codesign_nested_macho.sh <root> <identity> [skip-path]}"
IDENTITY="${2:?Usage: codesign_nested_macho.sh <root> <identity> [skip-path]}"
SKIP_PATH="${3:-}"

if [[ ! -d "${ROOT}" ]]; then
    echo "Nested code root does not exist: ${ROOT}" >&2
    exit 1
fi

signed_count=0
while IFS= read -r -d '' candidate; do
    if [[ -n "${SKIP_PATH}" && "${candidate}" == "${SKIP_PATH}" ]]; then
        continue
    fi
    if /usr/bin/file -b "${candidate}" | /usr/bin/grep -Eq "Mach-O|MetalLib executable"; then
        if ! sign_output=$(/usr/bin/codesign \
            --force \
            --timestamp \
            --options runtime \
            --sign "${IDENTITY}" \
            "${candidate}" 2>&1); then
            echo "Failed to sign nested code: ${candidate}" >&2
            echo "${sign_output}" >&2
            exit 1
        fi
        (( signed_count += 1 ))
    fi
done < <(/usr/bin/find "${ROOT}" -type f -print0)

echo "Developer ID signed ${signed_count} nested Mach-O files under ${ROOT}"
