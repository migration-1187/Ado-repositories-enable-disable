#!/usr/bin/env bash

# Enable Azure DevOps repositories previously disabled by ado2gh.
# CSV format: org,teamproject,repo
# Usage: bash enable_repo.sh [--csv path/to/disable_repo.csv]
# Requires: ADO_PAT, curl, jq

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_PATH="${SCRIPT_DIR}/disable_repo.csv"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)
            CSV_PATH="$2"
            shift 2
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ ! -f "${CSV_PATH}" ]]; then
    echo "[ERROR] CSV file not found: ${CSV_PATH}"
    exit 1
fi

if [[ -z "${ADO_PAT:-}" ]]; then
    echo "[ERROR] ADO_PAT environment variable is not set."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required but was not found."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq is required but was not found."
    exit 1
fi

TOTAL_REPOS=$(($(wc -l < "${CSV_PATH}") - 1))

if [[ ${TOTAL_REPOS} -lt 1 ]]; then
    echo "[ERROR] No repositories found in ${CSV_PATH}"
    exit 1
fi

echo "=========================================="
echo "ENABLE ADO REPOSITORIES"
echo "=========================================="
echo "CSV File: ${CSV_PATH}"
echo "Repositories to enable: ${TOTAL_REPOS}"
echo "=========================================="
echo ""

SUCCESS=0
FAILED=0
LINE_NUM=0
TEMP_RESPONSE=$(mktemp)
trap 'rm -f "${TEMP_RESPONSE}"' EXIT

while IFS=',' read -r org teamproject repo; do
    ((LINE_NUM++))

    [[ ${LINE_NUM} -eq 1 ]] && continue

    org="${org%$'\r'}"
    teamproject="${teamproject%$'\r'}"
    repo="${repo%$'\r'}"

    [[ -z "${org}" || -z "${teamproject}" || -z "${repo}" ]] && continue

    echo "[INFO] Processing: ${org}/${teamproject}/${repo}"

    LIST_URL="https://dev.azure.com/${org}/${teamproject}/_apis/git/repositories?api-version=7.1"

    RESPONSE=$(curl -sS -u ":${ADO_PAT}" "${LIST_URL}")

    REPO_ID=$(echo "${RESPONSE}" | \
        jq -r --arg repo "${repo}" \
        '.value[]? | select(.name == $repo) | .id' | head -1)

    if [[ -z "${REPO_ID}" || "${REPO_ID}" == "null" ]]; then
        echo "[FAILED] Repository not found: ${repo}"
        ((FAILED++))
        echo ""
        continue
    fi

    echo "[INFO] Repository ID: ${REPO_ID}"

    PATCH_URL="https://dev.azure.com/${org}/${teamproject}/_apis/git/repositories/${REPO_ID}?api-version=7.1"

    HTTP_CODE=$(curl -sS \
        -u ":${ADO_PAT}" \
        -X PATCH \
        -H "Content-Type: application/json" \
        -d '{"isDisabled":false}' \
        -o "${TEMP_RESPONSE}" \
        -w "%{http_code}" \
        "${PATCH_URL}")

    if [[ "${HTTP_CODE}" == "200" ]]; then
        echo "[SUCCESS] Enabled: ${repo}"
        ((SUCCESS++))
    else
        echo "[FAILED] Could not enable: ${repo}"
        echo "[INFO] HTTP Status: ${HTTP_CODE}"
        echo "[INFO] Azure DevOps response:"
        cat "${TEMP_RESPONSE}" 2>/dev/null || true
        echo ""
        ((FAILED++))
    fi

    echo ""
done < "${CSV_PATH}"

echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo "Total: ${TOTAL_REPOS} | Enabled: ${SUCCESS} | Failed: ${FAILED}"
echo "=========================================="

if [[ ${FAILED} -gt 0 ]]; then
    exit 1
fi

exit 0
