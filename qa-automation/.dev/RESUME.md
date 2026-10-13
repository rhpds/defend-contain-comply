# DCC QA solve — resume notes

DEV-ONLY. Not a deliverable. Where to pick up the per-task live-test loop.
Last updated: 2026-09-30.

## Environment state (as of last session)

- Namespace: `sandbox-5b8jr-zt-ansiblebu` on `ocpvdev01` (fresh deploy — the
  prior namespace, `sandbox-j9lwg-zt-ansiblebu`, hit an unrelated host bug:
  `central`'s systemd was built `-BPF_FRAMEWORK`, which breaks crun's
  systemd-cgroup eBPF device-filter install for `podman start` under
  `machine.slice`. Not a lab bug — just re-deployed instead of chasing it).
- Dev harness invocation unchanged from before (see below). Pod name changes
  per deploy — get it fresh with `oc get pods -n <ns> | grep showroom`.

## Dev harness invocation (how live tests are run)

Files are synced into the showroom runner pod at `/tmp/qadev/qa-automation/...`
then run through `.dev/run.yml`, which builds the inventory from `BASTION_*`
env and includes one task file via `-e tut=<path>`.

```bash
POD=<current showroom pod name>   # oc get pods -n <ns> | grep showroom
NS=<current namespace>
# sync a changed file:
oc cp qa-automation/tasks/solve_module_01_defend.yml "$NS/$POD":/tmp/qadev/qa-automation/tasks/solve_module_01_defend.yml -c runner
# run (log to a file in-pod; piping to tail swallows buffered output):
oc exec "$POD" -n "$NS" -c runner -- bash -lc "env BASTION_HOST=central BASTION_USER=rhel BASTION_PASSWORD='ansible123!' BASTION_PORT=22 \
  ansible-playbook /tmp/qadev/qa-automation/.dev/run.yml \
  -e tut=/tmp/qadev/qa-automation/tasks/solve_module_01_defend.yml > /tmp/run.log 2>&1; echo EXIT=\$?"
oc exec "$POD" -n "$NS" -c runner -- bash -lc 'grep -E "PLAY RECAP" -A3 /tmp/run.log; grep -iE "fatal|failed=[1-9]" /tmp/run.log'
```

Direct API probing from central (learn a shape before writing a task):
```bash
oc exec "$POD" -n "$NS" -c runner -- bash -lc "sshpass -p 'ansible123!' ssh -o StrictHostKeyChecking=no rhel@central 'curl -sk -u admin:\"ansible123!\" <URL>'"
```

Creds: AAP admin `admin` / `ansible123!`; Gitea admin `gitea` / `ansible123!`.
All default to `BASTION_PASSWORD` in `vars/solve.yml`.

## Module 1 — DONE, fully idempotent (verified 2x replay, identical recap
`ok=41 skipped=20` both times) on sandbox-5b8jr-zt-ansiblebu

- **M1-A** (Vulnerability Containment on rhel01): DONE, green, idempotent.
- **M1-B** (publish rulebook to discoverable path + EDA project sync): DONE,
  green, idempotent.
- **M1-C** (Splunk→EDA bridge): DONE, green, idempotent. All four pieces
  built: Token Event Stream credential, event stream, rulebook activation,
  Splunk add-on environment.
- **M1-D** (deploy app to rhel02): DONE, green, idempotent (after the
  flapping-guard fix below).
- **M1-E** (automated chain: Splunk detect → EDA rule → AAP containment on
  rhel02): DONE, green, idempotent. The real chain fires every time (fallback
  direct-launch path has never been exercised in testing).

### Bugs found and fixed while building M1-C/M1-D/M1-E (2026-09-30)

These are genuine corrections to SOLVE_SCOPE.md/QA_SOLVE_IMPLEMENTATION_PLAN.md,
not just implementation notes — read them before touching this code again.

1. **`source_mappings` schema (M1-C activation).** It's a JSON-*encoded string*,
   not a nested object, requiring exactly four keys: `source_name`,
   `event_stream_id`, `event_stream_name`, `rulebook_hash`. `source_name` is
   NOT read off the rulebook's own `sources:` block — EDA auto-assigns
   positional names (e.g. `__SOURCE_1`) to unnamed sources. Authoritative
   source: `GET /api/eda/v1/rulebooks/{id}/sources/`, which also reports the
   correct `rulebook_hash` (sha256 of the ruleset YAML text — computable
   client-side and confirmed to match). `eda_credentials` must include the
   Controller token credential (`DCC Controller Token`) or EDA rejects with
   "rulebook requires a RH AAP credential" before even validating
   `source_mappings`.

2. **Splunk add-on `auth_type=token` is a dead end (M1-C Splunk env).**
   `ansible_addon_for_splunk`'s `integration_client.py` only implements
   `auth_type` "basic" and "apikey"/"api_key" — `"token"` (what
   SOLVE_SCOPE.md §A.5 documented, and what the task originally used) silently
   falls through to *no authentication at all*. The add-on then gets HTTP 400
   "Authorization header is missing" from EDA's event-stream receptor and logs
   it as a generic "Request failed with status=400" with no further detail.
   **Fix: `auth_type: apikey`.** That path sends `Authorization: Bearer
   <token>`, which EDA accepts (it strips the scheme — confirmed the receptor
   also accepts the bare token with no scheme at all, but rejects
   `Splunk <token>` with 403 "Token mismatch").

3. **M1-E's original trigger mechanism (posting straight at the EDA receptor)
   was wrong.** The shipped `lab/templates/splunk-alert-payload-rhel02.json`
   does NOT match the rulebook's condition shape
   (`event.payload.search_name` / `event.payload.results.host`) — it's a
   generic vulnerability-detection record, not an EDA event envelope. It's
   meant for **Splunk HEC ingestion** (index=main, sourcetype=linux_secure),
   letting the real "DCC CVE Alert" saved search (`stats count by host`,
   cron `*/1 * * * *`) find it and fire the add-on's actual webhook action —
   the same path a real Splunk detection takes. This is the only path that
   produces the documented payload envelope. Confirmed by reading
   `ansible_addon_for_splunk`'s `integration_client.py` inside the Splunk
   container (`podman exec splunk cat .../bin/integration_client.py`) — it
   wraps results as `{sid, search_name, ..., results: chunk}`.
   - Dispatching the saved search via the wildcarded `/servicesNS/-/-/...`
     namespace 400s ("Cannot edit/create a saved search for wildcarded
     users..."); must dispatch via the owning user+app namespace:
     `/servicesNS/admin/ansible_addon_for_splunk/saved/searches/<name>/dispatch`.
   - Dispatching without `trigger_actions=1` runs the search but does NOT
     fire the alert action even if results match.

4. **`launch_type` cannot prove an EDA-triggered launch.** SOLVE_SCOPE.md
   proposed checking the resulting workflow job's `launch_type != manual` as
   proof the automated chain fired it. In practice `launch_type` reads
   `manual` even when EDA's `run_workflow_template` action launched it —
   ansible-rulebook calls the same launch API a human would, so AAP can't
   distinguish the caller that way. **Use the EDA audit-rules chain instead:**
   `GET /api/eda/v1/audit-rules/` → `/audit-rules/{id}/events/` (shows the
   matched event payload) and `/audit-rules/{id}/actions/` (shows
   `run_workflow_template` succeeded + the resulting job URL). This is
   authoritative and was used to confirm M1-E end to end.

5. **M1-D/M1-E "flapping" idempotency bug (found via a 3rd replay, not the
   first two).** M1-D's guard checked `http://rhel02/` **from central**, i.e.
   across rhel02's public interface. Once M1-E succeeds, containment
   deliberately blocks that interface by design — so the guard couldn't tell
   "not yet deployed" apart from "deployed and now (correctly) firewalled",
   and kept re-launching `DEFEND - Deploy Application`, which reset rhel02
   and undid M1-E's containment, forcing M1-E to redo the whole chain on
   every replay. **Fix: check locally** (`delegate_to: rhel02`, curl
   `http://127.0.0.1/`) — loopback traffic to a locally-owned IP doesn't
   traverse the firewalled interface, so it reads correctly regardless of
   containment state. General lesson for any future guard on a host that
   later gets firewalled: never check "is it deployed" via a path that a
   later step is expected to block.

## Reusable machinery (done, green)

- `tasks/preflight.yml` — 4 gates.
- `tasks/_launch_job.yml` — launch JT + poll + assert.
- `tasks/_launch_workflow.yml` — launch WFJT + poll + assert. Auto-approve
  stage still DEFERRED to M2-E (see NOTE in file). Body gates
  limit/extra_vars on the WFJT's ask_* flags.
- `tasks/verify_services.yml` + `healthcheck.yml` (refactored, green).
- `tasks/solve_module_01_defend.yml` — M1-A through M1-E, all DONE (see
  above).
- `tasks/solve_module_02_contain.yml` — M2-C (Policy-Gated Patching workflow
  nodes) DONE, green, convergent (identifier-idempotent, re-verified on the
  new namespace with different underlying JT ids — confirms resolve-by-name
  design holds across redeploys). M2-A/D/E TODO.

## Module 2 — DONE (M2-A, C, D, E all built and passing; M2-B stays a
documented no-op)

- **M2-A** (backup markers): DONE, green. Markers were already present on
  both hosts at deploy time on this namespace (contradicts SOLVE_SCOPE.md
  §4.3's "absent" assumption) — task handles either starting state fine.
- **M2-C** (Policy-Gated Patching nodes): DONE, green, convergent (carried
  over from before, re-verified this session).
- **M2-D** (OPA/execution-policy wiring): DONE, green, idempotent. Verified
  the separation-of-duties effect live: launching WFJT 27 as `admin` returns
  HTTP 201 (the *workflow* launch succeeds) but its Pre-Patch Check node
  immediately errors with the OPA violation message ("user 'admin' is not
  authorized for patching operations...") — the denial happens at node
  scheduling, not at the workflow-launch API call. Don't assert on the
  launch's own status code for this check.
- **M2-E** (patch rhel01 as security_engineer + auto-approve): DONE.
  Added the auto-approve block to `tasks/_launch_workflow.yml` — poll
  `workflow_nodes` for one whose `summary_fields.job.type ==
  "workflow_approval"` and `status == "pending"`, then POST
  `/workflow_approvals/{that job's id}/approve/` (not the workflow job's own
  id). Verified two ways rather than one live run of the coded task, because
  the patch can't be reversed to re-test the create path (the errata repo
  only carries patched httpd versions once patched — there's no downgrade
  template and yum has no route back to 2.4.57-5.el9):
    1. Manually walked every API call the task now automates (launch as
       security_engineer → poll nodes → approve id 125 → poll to completion)
       against real workflow job 123 — succeeded, rhel01 ended on
       `httpd-2.4.62-13.el9_8.6`.
    2. Isolated the new dotted-attribute `selectattr`/`map` Jinja (e.g.
       `selectattr('summary_fields.job.type', 'equalto', 'workflow_approval')`)
       into a standalone test playbook against the *exact* real JSON shape
       captured from that job — confirmed it correctly extracts
       `approval_id=125`.
  The guard (skip if rhel01 httpd is already past `vulnerable_httpd_version`)
  and final assert both ran for real and pass.

## Module 3 — DONE

- **M3-A** (`tasks/solve_module_03_comply.yml`, new file): launches
  `Compliance and Hardening` (WFJT 28, 7 nodes), guarded on the pushed image
  already existing in rhel01's *local* registry (container `workshop-registry`
  on rhel01 itself, port 5000 — NOT on central; confirmed by reading
  `lab/playbooks/comply/push-to-registry.yml` from Gitea). Image/tag:
  `parasol-app:latest`. Ran clean end-to-end on the first attempt (workflow
  job 135, successful) and idempotent on replay (guard skips, re-verify
  still passes).

## e2e.yml wiring — DONE

`e2e.yml` fully rewritten per plan §5: play 1 adds `central` (group `bastion`)
plus `rhel01`/`rhel02` (group `targets`, for delegate_to); play 2 runs on
`bastion` only (so `inventory_hostname == central`, matching
`validation-central.sh` naming), loads `vars/solve.yml`, runs
`tasks/preflight.yml`, then loops `modules_in_order` (from `ui-config.yml`,
unchanged behavior for `index`/`overview`/`conclusion` — no solve entry, no
validation script, so run_script.yml's existing skip logic no-ops them) via a
new small helper `tasks/solve_and_validate_module.yml` (solve → validate →
record PASS). **Note:** `ansible.builtin.block` does NOT support `loop` in
Ansible — that's why the per-module solve+validate+record sequence had to be
split into its own included file rather than inlined as a block in e2e.yml.

Verified live on sandbox-5b8jr-zt-ansiblebu (already-solved lab, so this was
a full wiring + idempotency test, not a fresh-deploy destructive run):
- Full `ansible-playbook e2e.yml` run: `EXIT=0`, `failed=0`, all 6 modules
  (including the 3 no-solve ones) reported PASS in the final summary.
  `module-01-defend` validation genuinely ran the shipped script and printed
  "all 5 job templates and 1 workflow template present in Automation
  Controller" — confirms the wiring to the real `validation-central.sh`
  files works, not just the solve side.
- Re-ran immediately after: `EXIT=0`, `failed=0` again; remaining
  `changed=4` is just `state: touch` (M2-A) and `ansible.builtin.shell`
  (validation script execution) — both modules always report changed
  regardless of actual state, not evidence of repeated destructive work.
- `healthcheck.yml` still green after all of the above (`ok=8 failed=0`).

**Not yet tested:** a *fresh-deploy* destructive run of `e2e.yml` (build
order §9.4 item 1) — everything above ran against a lab this session had
already solved task-by-task. The individual solve tasks were each proven
against real state transitions earlier in this session (see Module 1/2/3
sections above), so the wiring risk that's untested is specifically:
ui-config.yml module-name matching, inventory/delegate_to setup, and the
preflight gate's behavior on a truly fresh lab — not the solve logic itself.

## Remaining work

- A fresh-deploy full run of `e2e.yml` (see note above) — needs a new
  namespace since this one is now fully solved (rhel01 patched, rhel02
  contained, image pushed — no clean path back to "fresh" for a from-scratch
  test).
- `preflight.yml`'s §4.3 "baseline: not already solved" checks and
  `force_resolve` flag from the original plan were never implemented —
  current `preflight.yml` only has the 4 connectivity/resource-presence
  gates (§4.1/4.2 equivalent). Not blocking (idempotency is handled per-task
  via each solve file's own guards instead), but worth deciding whether it's
  still wanted.

## Guardrails (standing)

- Do NOT modify `setup-automation/` or `runtime-automation/` (learner-facing).
- e2e.yml renders the lab unusable — only for capacity/testing runs.
- Live-env: confirm `oc project` first; gather state before changes; state exact
  oc command and wait for thumbs-up before create/delete/patch; never echo the
  controller password.
- Build one task at a time, live-test each before writing the next.
- Idempotency isn't proven by one clean re-run — the M1-D/E flapping bug only
  showed up on the 3rd replay because the 2nd one happened to also "fix" the
  state it broke. Replay at least twice after any change that touches a guard.
