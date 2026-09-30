#!/bin/bash
# Module 02 (CONTAIN) -- validation.
#
# All CONTAIN resources are created at deploy time by lab/setup/configure-aap.yml,
# so there is no learner-produced state to inspect. This check confirms the job
# templates and workflow the module walks through are actually present in
# Automation Controller.
#
# Sourced by qa-automation/tasks/run_script.yml with `set -e` active and
# fail_validation() already defined, so every fallible command is guarded.

# run_script.yml turns on `set -x` before sourcing. Disable it so the controller
# password does not land in the task output or the per-module .log file.
set +x

CONTROLLER_HOST="${CONTROLLER_HOST:-control}"
CONTROLLER_USER="${CONTROLLER_USER:-admin}"
CONTROLLER_PASSWORD="${CONTROLLER_PASSWORD:-ansible123!}"
CONTROLLER_API="https://${CONTROLLER_HOST}/api/controller/v2"

# Stand-alone fallback so the script is also runnable by hand.
if ! command -v fail_validation >/dev/null 2>&1; then
  fail_validation() {
    echo "= FAIL VALIDATION BEGIN"
    printf '%s\n' "$@"
    echo "= FAIL VALIDATION END"
    return 1
  }
fi

# Fetch every name from a paginated list endpoint. Picks up nested summary_fields
# names too, which is harmless -- we only ever test for exact template names.
dcc_fetch_names() {
  _dcc_body=""
  if ! _dcc_body="$(curl -sfk --max-time 60 \
      -u "${CONTROLLER_USER}:${CONTROLLER_PASSWORD}" \
      "${CONTROLLER_API}/$1/?page_size=200")"; then
    return 1
  fi
  printf '%s' "$_dcc_body" | tr '{,' '\n\n' \
    | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

DCC_MISSING=""

dcc_require() {
  # $1 = newline-delimited haystack, $2 = exact name, $3 = kind label
  if printf '%s\n' "$1" | grep -Fxq "$2"; then
    return 0
  fi
  DCC_MISSING="${DCC_MISSING}
  - ${3}: ${2}"
}

DCC_JOB_TEMPLATES=""
DCC_WORKFLOWS=""
DCC_UNREACHABLE=""

if ! DCC_JOB_TEMPLATES="$(dcc_fetch_names job_templates)"; then
  DCC_UNREACHABLE="job_templates"
fi
if ! DCC_WORKFLOWS="$(dcc_fetch_names workflow_job_templates)"; then
  DCC_UNREACHABLE="${DCC_UNREACHABLE} workflow_job_templates"
fi

if [ -n "$DCC_UNREACHABLE" ]; then
  fail_validation \
    "Module 02 (CONTAIN): could not reach the Automation Controller API at ${CONTROLLER_API}." \
    "Failed endpoints: ${DCC_UNREACHABLE}" \
    "Check that the control node is up and the admin credentials are still valid."
fi

dcc_require "$DCC_JOB_TEMPLATES" "CONTAIN - Pre-Patch Check"          "job template"
dcc_require "$DCC_JOB_TEMPLATES" "CONTAIN - Patch System"             "job template"
dcc_require "$DCC_JOB_TEMPLATES" "CONTAIN - Post-Patch Verify"        "job template"
dcc_require "$DCC_JOB_TEMPLATES" "CONTAIN - Report Compliance"        "job template"
dcc_require "$DCC_JOB_TEMPLATES" "CONTAIN - Update Maintenance Window" "job template"
dcc_require "$DCC_WORKFLOWS"     "Policy-Gated Patching"              "workflow template"

if [ -n "$DCC_MISSING" ]; then
  fail_validation \
    "Module 02 (CONTAIN): the following Automation Controller resources are missing:${DCC_MISSING}" \
    "" \
    "These are created at deploy time by lab/setup/configure-aap.yml. If they are" \
    "absent, AAP configuration did not complete successfully."
fi

echo "Module 02 (CONTAIN): all 5 job templates and 1 workflow template present in Automation Controller."
