#!/usr/bin/env bash
# Build the workflow fixture the Automation Portal consumes, then prove it runs.
# Usage: scripts/portal-workflow.sh <host>
#
# Deliberately *not* the same graph as workflow-e2e.sh. That one exists to prove
# approval nodes work on ACE, and it pauses on purpose. A paused workflow is
# useless as a portal fixture: the portal has no approve/deny path, so a launch
# from the UI would hang forever with nothing to click. This one runs straight
# through.
#
#     Step 1  ->  Step 2  ->  Step 3
#
# The workflow carries its own survey, because that -- not the job templates'
# surveys -- is what the portal renders on the launch form.
#
# Everything goes through the envoy front door on 443: the controller enforces
# JWT-only auth once RESOURCE_SERVER['URL'] is set.
#
# Idempotent: every object is looked up by name first and reused if present.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: scripts/portal-workflow.sh <host>    # e.g. scripts/portal-workflow.sh 192.168.1.45" >&2
  exit 2
fi
HOST="$1"
PASS="$(cat .secrets/admin_password)"
API="https://${HOST}/api/controller/v2"
CURL=(curl -sk -u "admin:${PASS}" -H 'Content-Type: application/json')

WF_NAME="ACE Portal Demo Workflow"
step() { printf '\n== %s\n' "$*"; }
die()  { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

id_of() {
  "${CURL[@]}" -G "$API/$1/" --data-urlencode "name=$2" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["id"] if r else "")'
}

ensure() {
  local ep="$1" name="$2" body="$3" id
  id="$(id_of "$ep" "$name")"
  if [ -n "$id" ]; then echo "$id"; return; fi
  "${CURL[@]}" -X POST "$API/$ep/" -d "$body" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or sys.exit("create failed: "+json.dumps(d)[:300]))'
}

step "Fixtures"
ORG="$(id_of organizations Default)"
INV="$(id_of inventories 'Demo Inventory')"
PRJ="$(id_of projects 'Demo Project')"
[ -n "$ORG$INV$PRJ" ] || die "the Demo org/inventory/project are missing -- run scripts/e2e.sh first"
echo "org=$ORG inventory=$INV project=$PRJ"

jt() {
  ensure job_templates "$1" "$(python3 -c '
import json,sys
print(json.dumps({"name": sys.argv[1], "job_type": "run", "inventory": int(sys.argv[2]),
                  "project": int(sys.argv[3]), "playbook": "hello_world.yml"}))' "$1" "$INV" "$PRJ")"
}
JT1="$(jt 'Portal Demo - Step 1')"
JT2="$(jt 'Portal Demo - Step 2')"
JT3="$(jt 'Portal Demo - Step 3')"
echo "job templates: 1=$JT1 2=$JT2 3=$JT3"

step "Workflow job template"
WF="$(ensure workflow_job_templates "$WF_NAME" \
      "$(python3 -c 'import json,sys; print(json.dumps({
          "name": sys.argv[1], "organization": int(sys.argv[2]),
          "description": "Three steps, no approval node -- the fixture the portal launches.",
          "ask_variables_on_launch": True}))' "$WF_NAME" "$ORG")")"
echo "workflow id=$WF"

step "Survey on the workflow"
# The portal builds its launch form from the WORKFLOW's survey_spec, not from
# the surveys on the templates inside it.
"${CURL[@]}" -X POST "$API/workflow_job_templates/$WF/survey_spec/" -d '{
  "name": "Portal demo survey",
  "description": "rendered by the portal launch form",
  "spec": [
    {"question_name": "Environment", "question_description": "where this runs",
     "variable": "target_env", "type": "multiplechoice", "required": true,
     "choices": ["dev", "staging", "prod"], "default": "dev"},
    {"question_name": "Change ticket", "question_description": "free text",
     "variable": "change_ticket", "type": "text", "required": false, "default": "NONE"}
  ]
}' >/dev/null
"${CURL[@]}" -X PATCH "$API/workflow_job_templates/$WF/" -d '{"survey_enabled": true}' >/dev/null
echo "survey enabled on $WF_NAME"

existing_nodes="$("${CURL[@]}" "$API/workflow_job_templates/$WF/workflow_nodes/" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')"

if [ "$existing_nodes" = "0" ]; then
  step "Wiring the graph"
  node() {
    "${CURL[@]}" -X POST "$API/workflow_job_templates/$WF/workflow_nodes/" \
      -d "{\"unified_job_template\": $1}" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
  }
  N1="$(node "$JT1")"
  N2="$(node "$JT2")"
  N3="$(node "$JT3")"
  "${CURL[@]}" -X POST "$API/workflow_job_template_nodes/$N1/success_nodes/" -d "{\"id\": $N2}" >/dev/null
  "${CURL[@]}" -X POST "$API/workflow_job_template_nodes/$N2/success_nodes/" -d "{\"id\": $N3}" >/dev/null
  echo "nodes: 1=$N1 2=$N2 3=$N3"
else
  echo "graph already has $existing_nodes nodes -- reusing"
fi

step "Launch with survey answers"
WFJOB="$("${CURL[@]}" -X POST "$API/workflow_job_templates/$WF/launch/" \
  -d '{"extra_vars": {"target_env": "dev", "change_ticket": "CHG-0001"}}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or sys.exit("launch failed: "+json.dumps(d)[:300]))')"
echo "workflow job id: $WFJOB"

for i in $(seq 90); do
  STATUS="$("${CURL[@]}" "$API/workflow_jobs/$WFJOB/" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  case "$STATUS" in successful|failed|error|canceled) break ;; esac
  sleep 5
done
echo "workflow finished: $STATUS"
[ "$STATUS" = successful ] || die "workflow ended $STATUS -- expected successful"

step "Node results"
# Same shape the portal's buildWorkflowLayers.ts renders.
"${CURL[@]}" "$API/workflow_jobs/$WFJOB/workflow_nodes/" | python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=[]
for n in d["results"]:
    sf=n.get("summary_fields",{}); j=sf.get("job") or {}
    name=j.get("name") or (sf.get("unified_job_template") or {}).get("name") or "(empty)"
    st=j.get("status") or "did-not-run"
    print("   node %-5s %-30s %s" % (n["id"], name, st))
    if st != "successful": bad.append((name, st))
if len(d["results"]) != 3: sys.exit("expected 3 nodes, got %d" % len(d["results"]))
if bad: sys.exit("FAIL: nodes not successful: %r" % bad)
print("  asserted: all 3 nodes ran successfully")
'

step "Result"
echo "PORTAL FIXTURE READY -- workflow job template id $WF"
