#!/usr/bin/env bash
# Re-enable ADO repositories previously disabled via ado2gh.
# Usage: ./enable_repo.sh [--csv path/to/disable_repo.csv]
# Requires: ADO_PAT environment variable and curl.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_PATH="${SCRIPT_DIR}/disable_repo.csv"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)
      CSV_PATH="$2"; shift 2;;
    *)
      echo "[ERROR] Unknown option: $1"; exit 1;;
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

while IFS=',' read -r org teamproject repo; do
  ((LINE_NUM++))
  [[ ${LINE_NUM} -eq 1 ]] && continue

  org="${org%$'\r'}"
  teamproject="${teamproject%$'\r'}"
  repo="${repo%$'\r'}"

  [[ -z "${org}" || -z "${teamproject}" || -z "${repo}" ]] && continue

  echo "[INFO] Enabling: ${org}/${teamproject}/${repo}"

  # URL-encode project/repository names using curl itself.
  project_encoded=$(curl -sS -o /dev/null -w '%{url_effective}' --get --data-urlencode "v=${teamproject}" 'http://localhost/' 2>/dev/null | sed 's#^http://localhost/?v=##')
  repo_encoded=$(curl -sS -o /dev/null -w '%{url_effective}' --get --data-urlencode "v=${repo}" 'http://localhost/' 2>/dev/null | sed 's#^http://localhost/?v=##')

  # Resolve the repository and verify it exists.
  GET_URL="https://dev.azure.com/${org}/${project_encoded}/_apis/git/repositories/${repo_encoded}?api-version=7.1"
  HTTP_CODE=$(curl -sS -u ":${ADO_PAT}" -o /tmp/enable_repo_get.json -w "%{http_code}" "${GET_URL}")

  if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "[FAILED] Could not find/read repo '${repo}' (HTTP ${HTTP_CODE})"
    ((FAILED++))
    echo ""
    continue
  fi

  # Azure DevOps Repositories - Update: isDisabled=false re-enables the repository.
  PATCH_URL="https://dev.azure.com/${org}/${project_encoded}/_apis/git/repositories/${repo_encoded}?api-version=7.1"
  HTTP_CODE=$(curl -sS -u ":${ADO_PAT}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d '{"isDisabled":false}' \
    -o /tmp/enable_repo_patch.json \
    -w "%{http_code}" \
    "${PATCH_URL}")

  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "[SUCCESS] Enabled: ${repo}"
    ((SUCCESS++))
  else
    echo "[FAILED] Could not enable: ${repo} (HTTP ${HTTP_CODE})"
    cat /tmp/enable_repo_patch.json 2>/dev/null || true
    echo ""
    ((FAILED++))
  fi

  echo ""
done < "${CSV_PATH}"

rm -f /tmp/enable_repo_get.json /tmp/enable_repo_patch.json

echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo "Total: ${TOTAL_REPOS} | Enabled: ${SUCCESS} | Failed: ${FAILED}"
echo "=========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
