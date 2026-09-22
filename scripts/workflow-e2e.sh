#!/usr/bin/env bash
# Build a workflow job template with an approval node, then prove it runs.
# Usage: scripts/workflow-e2e.sh <host>
#
# Everything goes through the envoy front door on 443. It has to: once the
# controller has RESOURCE_SERVER['URL'] set it enforces JWT-only auth and
# answers 401 to anything that reaches it directly, so the gateway is the only
# way in.
#
# The graph this builds:
#
#     Step A  ->  approval  -+-> Step B   (on approve)
#                            `-> Step C   (on deny)
#
# Idempotent: every object is looked up by name first and reused if present.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: scripts/workflow-e2e.sh <host>    # e.g. scripts/workflow-e2e.sh 192.168.1.45" >&2
  exit 2
fi
HOST="$1"
PASS="$(cat .secrets/admin_password)"
API="https://${HOST}/api/controller/v2"
CURL=(curl -sk -u "admin:${PASS}" -H 'Content-Type: application/json')

WF_NAME="ACE Demo Workflow"
step() { printf '\n== %s\n' "$*"; }
die()  { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

# id_of <endpoint> <name>  -> prints the id, or nothing
id_of() {
  "${CURL[@]}" -G "$API/$1/" --data-urlencode "name=$2" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["id"] if r else "")'
}

# ensure <endpoint> <name> <json>  -> prints the id, creating only if absent
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
[ -n "$ORG$INV$PRJ" ] || die "the Demo org/inventory/project are missing — run scripts/e2e.sh first"
echo "org=$ORG inventory=$INV project=$PRJ"

jt() {  # jt <name>
  ensure job_templates "$1" "$(python3 -c '
import json,sys
print(json.dumps({"name": sys.argv[1], "job_type": "run", "inventory": int(sys.argv[2]),
                  "project": int(sys.argv[3]), "playbook": "hello_world.yml"}))' "$1" "$INV" "$PRJ")"
}
JT_A="$(jt 'ACE Workflow - Step A')"
JT_B="$(jt 'ACE Workflow - Step B (approved)')"
JT_C="$(jt 'ACE Workflow - Step C (denied)')"
echo "job templates: A=$JT_A B=$JT_B C=$JT_C"

step "Survey on Step B"
# The portal POC reuses the job-template survey helpers for workflows, so at
# least one template in the graph needs a real survey to exercise that path.
"${CURL[@]}" -X POST "$API/job_templates/$JT_B/survey_spec/" -d '{
  "name": "Step B survey", "description": "exercises prompt-on-launch",
  "spec": [{"question_name": "Greeting", "variable": "greeting", "type": "text",
            "required": true, "default": "hello from the survey"}]
}' >/dev/null
"${CURL[@]}" -X PATCH "$API/job_templates/$JT_B/" -d '{"survey_enabled": true}' >/dev/null
echo "survey enabled on Step B"

step "Workflow job template"
WF="$(ensure workflow_job_templates "$WF_NAME" \
      "$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "organization": int(sys.argv[2])}))' \
         "$WF_NAME" "$ORG")")"
echo "workflow id=$WF"

existing_nodes="$("${CURL[@]}" "$API/workflow_job_templates/$WF/workflow_nodes/" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')"

if [ "$existing_nodes" = "0" ]; then
  step "Wiring the graph"
  node() {  # node <unified_job_template_id>
    "${CURL[@]}" -X POST "$API/workflow_job_templates/$WF/workflow_nodes/" \
      -d "{\"unified_job_template\": $1}" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
  }
  N_A="$(node "$JT_A")"
  N_B="$(node "$JT_B")"
  N_C="$(node "$JT_C")"

  # The approval node is made by turning an empty node into one -- there is no
  # separate approval template to create first.
  N_APP="$("${CURL[@]}" -X POST "$API/workflow_job_templates/$WF/workflow_nodes/" -d '{}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  "${CURL[@]}" -X POST "$API/workflow_job_template_nodes/$N_APP/create_approval_template/" \
    -d '{"name": "ACE Workflow - Approve to continue", "description": "pauses the workflow", "timeout": 0}' >/dev/null

  "${CURL[@]}" -X POST "$API/workflow_job_template_nodes/$N_A/success_nodes/"   -d "{\"id\": $N_APP}" >/dev/null
  "${CURL[@]}" -X POST "$API/workflow_job_template_nodes/$N_APP/success_nodes/" -d "{\"id\": $N_B}"   >/dev/null
  "${CURL[@]}" -X POST "$API/workflow_job_template_nodes/$N_APP/failure_nodes/" -d "{\"id\": $N_C}"   >/dev/null
  echo "nodes: A=$N_A approval=$N_APP B=$N_B C=$N_C"
else
  echo "graph already has $existing_nodes nodes — reusing"
fi

# launch_and_settle <approve|deny> <node that must run> <node that must not>
#
# Asserts on NODE outcomes, not the workflow's own status. A denied approval
# still leaves the workflow `successful`: AWX reports whether the graph
# completed, not whether every branch passed. The branch that ran is the only
# thing that actually proves approve and deny do different things.
launch_and_settle() {
  local decision="$1" must_run="$2" must_not_run="$3" wfjob approval status i
  step "Launch, then $decision"
  wfjob="$("${CURL[@]}" -X POST "$API/workflow_job_templates/$WF/launch/" -d '{}' \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or sys.exit("launch failed: "+json.dumps(d)[:300]))')"
  echo "workflow job id: $wfjob"

  # Wait for the approval node to go pending. That it pauses at all is the
  # thing being proven -- a workflow that runs straight through has not
  # exercised the approval path.
  approval=""
  for i in $(seq 60); do
    approval="$("${CURL[@]}" -G "$API/workflow_approvals/" --data-urlencode 'status=pending' \
      | python3 -c "
import json,sys
for a in json.load(sys.stdin)['results']:
    if a.get('summary_fields',{}).get('source_workflow_job',{}).get('id') == $wfjob:
        print(a['id']); break")"
    [ -n "$approval" ] && break
    sleep 5
  done
  [ -n "$approval" ] || die "no approval went pending within 5 minutes — the approval node is not working"
  echo "approval $approval is pending — workflow paused"

  "${CURL[@]}" -X POST "$API/workflow_approvals/$approval/$decision/" -d '{}' >/dev/null
  echo "$decision sent"

  for i in $(seq 60); do
    status="$("${CURL[@]}" "$API/workflow_jobs/$wfjob/" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
    case "$status" in successful|failed|error|canceled) break ;; esac
    sleep 5
  done
  echo "workflow finished: $status"
  case "$status" in successful|failed) ;; *) die "workflow ended $status" ;; esac

  step "Node results for workflow job $wfjob"
  # This is the same shape the portal's buildWorkflowLayers.ts renders, so it
  # doubles as a check that the data the UI needs is really there.
  "${CURL[@]}" "$API/workflow_jobs/$wfjob/workflow_nodes/" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ran={}
for n in d['results']:
    sf=n.get('summary_fields',{}); j=sf.get('job') or {}
    name=j.get('name') or (sf.get('unified_job_template') or {}).get('name') or '(empty)'
    st=j.get('status') or 'did-not-run'
    ran[name]=st
    print('   node %-5s %-42s %s' % (n['id'], name, st))

must_run, must_not = sys.argv[1], sys.argv[2]
def find(frag):
    return next((v for k,v in ran.items() if frag in k), None)

got_run, got_skip = find(must_run), find(must_not)
if got_run in (None,'did-not-run'):
    sys.exit('FAIL: %r should have run after $decision, got %s' % (must_run, got_run))
if got_skip != 'did-not-run':
    sys.exit('FAIL: %r should NOT have run after $decision, got %s' % (must_not, got_skip))
appr = find('Approve to continue')
want_appr = 'successful' if '$decision' == 'approve' else 'failed'
if appr != want_appr:
    sys.exit('FAIL: approval node should be %s after $decision, got %s' % (want_appr, appr))
print('  asserted: %s ran, %s did not, approval %s' % (must_run, must_not, appr))
" "$must_run" "$must_not_run"
}

launch_and_settle approve 'Step B' 'Step C'
launch_and_settle deny    'Step C' 'Step B'

step "Result"
echo "WORKFLOW E2E PASSED"
