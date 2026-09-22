#!/usr/bin/env bash
# End-to-end verification through the envoy front door (run from the repo root).
# Usage: scripts/e2e.sh <host>
#
# The host is required. It used to default to 192.168.56.30, the Vagrant/Fusion
# box, which has not existed since that lab was retired -- so a bare run failed
# by timing out against nothing rather than saying what was wrong.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: scripts/e2e.sh <host>    # e.g. scripts/e2e.sh 192.168.1.45" >&2
  exit 2
fi
HOST="$1"
PASS="$(cat .secrets/admin_password)"
BASE="https://${HOST}"
CURL=(curl -sk -u "admin:${PASS}")

step() { printf '\n== %s\n' "$*"; }

step "UI login page via envoy :443"
curl -sk "${BASE}/" | grep -qi '<title' && echo OK

step "Gateway auth (/api/gateway/v1/me/)"
"${CURL[@]}" "${BASE}/api/gateway/v1/me/" | jq -r '.results[0].username // .username // "FAIL"'

step "Registered services"
"${CURL[@]}" "${BASE}/api/gateway/v1/services/" | jq -r '.results[] | "\(.api_slug) -> \(.service_path) (order \(.order))"'

step "Controller through the gateway (/api/controller/v2/ping/)"
"${CURL[@]}" "${BASE}/api/controller/v2/ping/" | jq -r '.instances[0].node, .instances[0].node_type'

step "EDA through the gateway (/api/eda/v1/status/)"
"${CURL[@]}" "${BASE}/api/eda/v1/status/" | jq -r '.status // "FAIL"'

step "Hub through the gateway (/api/galaxy/pulp/api/v3/status/)"
"${CURL[@]}" "${BASE}/api/galaxy/pulp/api/v3/status/" | jq -r 'if .database_connection.connected then "good" else "FAIL" end'

step "Launch Demo Job Template through the gateway"
JT=$("${CURL[@]}" "${BASE}/api/controller/v2/job_templates/?name=Demo+Job+Template" | jq -r '.results[0].id')
echo "job template id: ${JT}"
JOB=$("${CURL[@]}" -X POST "${BASE}/api/controller/v2/job_templates/${JT}/launch/" -H 'Content-Type: application/json' -d '{}' | jq -r '.id')
echo "job id: ${JOB}"

for _ in $(seq 1 60); do
    STATUS=$("${CURL[@]}" "${BASE}/api/controller/v2/jobs/${JOB}/" | jq -r '.status')
    echo "  status: ${STATUS}"
    case "${STATUS}" in
        successful) echo 'E2E PASSED'; exit 0 ;;
        failed|error|canceled) echo 'E2E FAILED'; exit 1 ;;
    esac
    sleep 5
done
echo 'E2E TIMED OUT'; exit 1
