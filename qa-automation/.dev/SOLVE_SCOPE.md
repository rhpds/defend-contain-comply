# Scope: Ansible Solve Automation for "Defend, Contain, Comply"

**Status:** Draft for review — upstream repo verified (§0) + live env verified (§0.1) + QA harness & approval endpoint verified (§0.2)
**Source of truth:** [LAB_SUMMARY.md](LAB_SUMMARY.md), `content/modules/ROOT/pages/`, `config/instances.yaml`, `setup-automation/`, `runtime-automation/`, and upstream `nmartins0611/zt-ans-defend-contain-comply` (branch `dev`), `lab/setup/*.yml`
**Author intent:** Automate the lab to its **final result state**, not click-for-click. Verify the environment is in the expected starting state *before* any solve action runs.

---

## 0. Upstream verification — what is actually injected into AAP

I cloned `nmartins0611/zt-ans-defend-contain-comply` (branch `dev`) and read `lab/setup/`.
These findings resolve the earlier open questions and are the authoritative basis for §5.

**Deploy-time config playbooks** (run by `setup-automation/tasks/configure-*.yml`):
`configure-app-server.yml`, `configure-aap.yml`, `configure-eda.yml` (on `control`);
`deploy-central-services.yml`, `configure-errata-repo.yml`, `configure-splunk-alerts.yml` (on `central`).
Constants live in `lab/setup/vars/workshop.yml`.

**What `configure-aap.yml` pre-creates (already present at deploy time — solve must NOT recreate):**
- **16 job templates** — all DEFEND (6, incl. `DEFEND - Restore Containment`), CONTAIN (5), COMPLY (6). *(Note: `DEFEND - Restore Containment` exists but is not in the lab guide — useful for reset/idempotency.)*
- **`security_engineer` user WITH password `ansible123!`** (`update_secrets: true`) + org-admin and workflow admin/approval/execute roles. → **The lab-guide "set the password" step (M2 Ex4) is redundant; solve skips it.**
- **Workflow `Vulnerability Containment`** — fully built (scan→contain→harden).
- **Workflow `Compliance and Hardening`** — fully built (7 nodes, on-success chain).
- **Workflow `Policy-Gated Patching`** — **created as an EMPTY SHELL.** The node-building tasks exist in `configure-aap.yml` but are tagged `patching_workflow` **and `never`**, so they do NOT run at deploy. The learner builds the nodes (M2 Ex3). → **This is a real solve task, with a shortcut: see M2-C.**

**What `configure-eda.yml` pre-creates:** EDA credential `DCC Controller Token` + EDA project `Defend, Contain, Comply` (synced from Gitea). Its own debug output states: *"Students will create: Token Event Stream, Rulebook Activation, and configure the Splunk add-on."* → **Those three are genuine solve tasks (M1-C).**

**Job templates already point at the SOLUTION playbooks:**
- `CONTAIN - Pre-Patch Check` runs `lab/playbooks/contain/pre-patch-check.yml` — the **complete, working** solution. The repo also ships `pre-patch-check-exercise.yml` (TODO stubs) purely as the learner decoy. → **Solve does NOT need to edit/commit any playbook for M2-B; the template already runs working code.**
- Same pattern for the EDA rulebook: `lab/extensions/eda/splunk-cve-alert.yml` is the complete solution; `splunk-cve-alert-exercise.yml` is the decoy.

**What is genuinely learner-configured (NOT injected — solve must do it):**
1. Policy-Gated Patching workflow nodes (M2-C).
2. EDA Token Event Stream + Rulebook Activation + Splunk add-on webhook (M1-C).
3. **AAP execution policy / OPA gateway wiring** — Settings→Policy OPA hostname `192.168.1.11` + org `Default` enforcement path `aap/gateway/decision`. The `dcc-execution-policy.rego` is loaded into OPA at deploy (`deploy-central-services.yml` copies `files/opa-policies/` into the OPA container), but the AAP-side wiring is not injected (M2-D).
4. Backup markers on rhel01/rhel02 (M2-A).

**All three OPA policies are loaded at deploy** (`dcc-patch-policy.rego`, `dcc-compliance.rego`, `dcc-execution-policy.rego` → mounted into the OPA container). Preflight OPA checks are therefore valid.

### 0.1 Live-environment verification (namespace `sandbox-j9lwg-zt-ansiblebu`, cluster `ocpvdev01`)

Confirmed against a running deployment (AAP 4.7.4, `oc` + Controller/EDA/OPA APIs, all read-only):

- **All 4 VMs Running** (`central`, `control`, `rhel01`, `rhel02`) + `gitea` and `showroom` pods. Routes/services match `config/instances.yaml` (app, app2, compliance-portal, control-https, eda-ui, gitea, opa-http, splunk). Showroom exposes wetty terminals for control/rhel01/rhel02/central.
- **16 DCC job templates present** (+ a stock `Demo Job Template`).
- **Workflow node counts confirm §0 exactly:** `Vulnerability Containment` = 3 nodes, `Compliance and Hardening` = 7 nodes, **`Policy-Gated Patching` = 0 nodes (empty shell)**.
- **`security_engineer` exists, non-superuser** (password pre-set — not queryable, but created with `ansible123!` per §0).
- **EDA:** project `Defend, Contain, Comply` synced (import completed); credential `DCC Controller Token` present; **event streams = 0, activations = 0** → confirms these are learner/solve-created (M1-C).
- **OPA:** all 3 policies loaded (`dcc-compliance`, `dcc-execution-policy`, `dcc-patch-policy`).
- **⚠ NEW — resolves Q2:** **EDA discovered 0 rulebooks from the project.** The shipped solution
  is at `lab/extensions/eda/splunk-cve-alert.yml`, which is NOT under the standard
  `extensions/eda/rulebooks/` path EDA scans — so nothing is auto-discovered. **The solve MUST
  commit the rulebook to `extensions/eda/rulebooks/splunk-cve-alert.yml` in the Gitea repo and
  re-sync the EDA project** before a rulebook activation can reference it. This matches the lab
  guide's create-file path. M1-B is therefore a real commit-and-sync task, not a no-op.

### 0.2 QA harness & approval endpoint (live-verified)

The solve does **not** get a bespoke orchestrator — it must plug into the existing showroom QA harness.

**Showroom QA endpoints (internal QA only, not learner-facing):**
- `POST https://showroom-<guid>.../stream/qa/healthcheck` → runs `qa-automation/healthcheck.yml`. **Non-destructive**, polled periodically to confirm services/containers are up. Verified live: passes clean (`central ok=7, failed=0` — all containers, ports, and AAP/OPA health endpoints OK).
- `POST https://showroom-<guid>.../stream/qa/e2e` → runs `qa-automation/e2e.yml`. **DESTRUCTIVE — solves the whole lab, leaving it un-usable by a learner.** Only for capacity planning / testing, never against a lab handed to a user.

**How e2e drives the solve — this defines our deliverable shape:**
`qa-automation/e2e.yml` reads module names from `ui-config.yml`
(`module-01-defend`, `module-02-contain`, `module-03-comply`) and, for each, runs
`runtime-automation/<module>/solve-<host>.sh` **then** `validation-<host>.sh` on the `central`
bastion (via `tasks/run_script.yml`, sourcing the `fail_validation` helper).

**GAP confirmed (local + upstream):** the module dirs ship `validation-central.sh` but **no
`solve-central.sh`** — so e2e currently *validates only, never solves*. **Our deliverable is the
missing `runtime-automation/module-0{1,2,3}-*/solve-central.sh` scripts.** To match the existing
harness they should be **bash + curl against the Controller/EDA/OPA APIs** (like the validation
scripts), run from `central`, idempotent, and emit `fail_validation`-style output on error.
This supersedes the standalone-orchestrator idea in §8.

**Approval endpoint — verified end to end on this dev env (then cleaned up):**
Created a throwaway workflow with one approval node, granted `security_engineer` the approval role,
launched it, and approved the pending gate **as `security_engineer`**:
`POST /api/controller/v2/workflow_approvals/{id}/approve/` → **HTTP 204**, approval
`status: successful`, `approved_by: security_engineer`. Throwaway workflow + job deleted; the three
real workflows remain intact. → **Resolves the M2-E approval question:** the solve polls
`/workflow_approvals/?status=pending`, then POSTs `.../approve/` with the `security_engineer`
credential. No host was touched (approval-only node).

**Confirmed constants (from `vars/workshop.yml`) — use verbatim, don't hardcode guesses:**
`target_cve: CVE-2024-38476`, `target_advisory: RHSA-2024:5138`,
`vulnerable_httpd_version: 2.4.57-5.el9`, `patched_httpd_version: 2.4.62-1.el9`,
org `Default`, inventory `DCC Workshop`, project `Defend, Contain, Comply`,
credential `DCC App Server`, scan EE `Trusted Pipeline EE` (`quay.io/nmartins/trusted-pipeline-ee:latest`),
registry port `5000`, Gitea repo `gitea/defend-contain-comply` at `http://gitea:3000`,
Splunk HEC token `a1b2c3d4-e5f6-7890-abcd-ef1234567890`.

---

## 1. Purpose

Produce Ansible automation that takes a freshly-provisioned DCC lab environment and drives it to
the exact end state a learner would reach after completing all three modules — so the lab can be
smoke-tested, demoed, or used as an instructor "solve." The automation must:

1. **Verify** the environment is healthy and in the expected *pre-solve* baseline first (fail fast, don't corrupt a half-broken lab).
2. **Solve** each module by reaching its terminal state, preferring existing AAP resources over reimplementing behaviour.
3. **Validate** the achieved end state (reuse the existing `runtime-automation/*/validation-central.sh` pattern where possible).

This is a **scope document only** — no solve code is written here.

---

## 2. Guiding principle: state, not steps

The lab is already backed by real automation. Every module's actions are performed by AAP job
templates and workflows that exist at deploy time (confirmed by the `validation-central.sh` scripts,
which assert 5+6+5 job templates and 3 workflows are present). The GUI steps a learner performs are
mostly *launching* those templates plus authoring a handful of artifacts.

Therefore the solve should **drive the AAP Controller API** (via `ansible.controller` /
`awx.awx` or `ansible.builtin.uri`) to launch the same templates and workflows, and **create the
few learner-authored artifacts** programmatically. It should not re-implement firewall/SELinux/patch
logic on the hosts directly — that would diverge from what the lab actually teaches and duplicate the
shipped playbooks.

**Decision point (see §7):** API-driven solve is the recommended approach. A host-direct fallback
is possible but out of scope unless the AAP-driven path proves unworkable.

---

## 3. Environment facts (grounding)

| Host | IP | Role | Solve touches |
|------|-----|------|---------------|
| `control` | 192.168.1.10 / `aap.example.org` | AAP Controller 2.6 + EDA | API target for launches, EDA config, execution policy |
| `central` | 192.168.1.11 | Splunk (8000/8088/8089), OPA (8181), errata repo (8085), compliance portal (8086) | OPA/Splunk verification, maintenance-window policy |
| `rhel01` | 192.168.1.13 | Primary app server, vulnerable `httpd-2.4.57-5.el9` | Backup marker, end-state assertions |
| `rhel02` | 192.168.1.14 | Second app server | App deploy target, backup marker, end-state assertions |
| `gitea` (container) | — | Repo `defend-contain-comply` (org `gitea`) | Rulebook + playbook edits, commits |

**Credentials (lab-static):** AAP `admin` / `ansible123!`; `security_engineer` / (to be set) `ansible123!`; SSH `rhel` / `ansible123!`; Splunk `admin` / `ansible123!`; Gitea `gitea` / `ansible123!`; EDA token `ansibleiscool`.

**Reusable assets already in repo:**
- `setup-automation/main.yml` — dynamic inventory + host vars pattern (copy the `add_host` block).
- `runtime-automation/*/validation-central.sh` — AAP API polling pattern (curl + name assertions).
- `qa-automation/healthcheck.yml`, `e2e.yml` — health-check harness to extend.

---

## 4. Pre-solve verification (gate — runs first, must pass)

A single "preflight" play that aborts the solve if the baseline is wrong. Grouped by layer:

### 4.1 Connectivity & platform
- [ ] SSH reachable on all four VMs (`wait_for_connection`).
- [ ] AAP Controller API reachable and authenticating at `https://control/api/controller/v2/ping`.
- [ ] EDA Controller API reachable at `https://control:8443` (or gateway path).
- [ ] OPA reachable: `GET http://central:8181/health` returns 200.
- [ ] Splunk reachable: management API `https://central:8089` responds; web UI 8000 up.
- [ ] Gitea reachable and `defend-contain-comply` repo present.
- [ ] Errata repo (8085) and compliance portal (8086) on `central` respond.

### 4.2 AAP resource presence (reuse validation-central.sh logic)
- [ ] All DEFEND/CONTAIN/COMPLY job templates present (16 total).
- [ ] All three workflows present: `Vulnerability Containment`, `Policy-Gated Patching`, `Compliance and Hardening`.
- [ ] Inventory `DCC Workshop` and projects (`Defend, Contain, Comply` EDA project, `DCC Workshop` project) present.
- [ ] `security_engineer` user exists.

### 4.3 Baseline state (confirm NOT already solved)
- [ ] `rhel01` `httpd` is the **vulnerable** version (`2.4.57-5.el9`), CVE-2024-38476 pending in `yum updateinfo`.
- [ ] `rhel01` both `eth0` and `eth1` in `public` firewall zone; `http`/`https` allowed (i.e., **not** yet contained).
- [ ] Portal on `rhel01` returns HTTP 200 externally.
- [ ] OPA has `dcc/patch_policy` and `policies/dcc-compliance.rego` loaded.
- [ ] Backup marker `/var/log/last-backup-timestamp` **absent** (Module 2 starting condition).

> Preflight is report-and-fail: it prints a per-check PASS/FAIL table and stops before any mutation
> if a required check fails. Idempotency note: some checks (e.g. "not already contained") are
> advisory when the solve is re-run — see §6 idempotency.

---

## 5. Solve tasks by target end-state

Each task lists **end state**, **mechanism**, and **verification**. Ordered by module dependency.

### Module 1 — DEFEND

**M1-A — rhel01 contained (manual-path equivalent)**
- *End state:* `eth0` in `internal-only` zone; `http`/`https` removed from `public`; httpd running & hardened (`ServerTokens Prod`, `ServerSignature Off`, security headers); SELinux booleans `httpd_can_network_connect|enable_cgi|can_sendmail|use_nfs` all off; AIDE cron present; `/var/log/containment-actions.log` written.
- *Mechanism:* Launch workflow `Vulnerability Containment` with `limit=rhel01` via controller API; wait for success.
- *Verify:* Reuse Module 1 host-side checks from lab guide (firewall zones, `sshd`/httpd config, `getsebool`, crontab).

**M1-B — EDA rulebook committed & project synced**
- *End state:* Rulebook discoverable by EDA (`extensions/eda/rulebooks/splunk-cve-alert.yml`); EDA project re-synced so it appears under `/api/eda/v1/rulebooks/`.
- *Verified live (§0.1):* EDA currently discovers **0 rulebooks** — the shipped copy at
  `lab/extensions/eda/` is not in the scanned path. **Solve must commit** the rulebook content
  (reuse the shipped solution from `lab/extensions/eda/splunk-cve-alert.yml`) to
  `extensions/eda/rulebooks/splunk-cve-alert.yml` in the Gitea repo, then trigger an EDA project sync.
- *Mechanism:* Create file via Gitea API (`POST /api/v1/repos/gitea/defend-contain-comply/contents/...`) or git push; then `POST /api/eda/v1/projects/{id}/sync/` and poll import_state=completed.
- *Verify:* `/api/eda/v1/rulebooks/` count ≥ 1 and lists `splunk-cve-alert.yml`.

**M1-C — Splunk→EDA channel wired**
- *End state:* Token Event Stream credential `Splunk EDA Token`, event stream `Splunk EDA`, Splunk add-on webhook `Splunk2EDA`, and rulebook activation `DCC CVE Alert Responder` — activation status **Running**.
- *Mechanism:* Create credential, event stream, and activation via EDA/controller API; configure Splunk add-on via Splunk REST (management API 8089) or its stored config.
- *Verify:* Activation status Running; event stream exists; Splunk add-on config points at `192.168.1.10` endpoint.

**M1-D — rhel02 app deployed**
- *End state:* Vulnerable httpd + portal + errata repo on `rhel02`; portal reachable.
- *Mechanism:* Launch `DEFEND - Deploy Application`, `limit=rhel02`.
- *Verify:* Portal on rhel02 HTTP 200; CVE detected on rhel02.

**M1-E — rhel02 contained via the automated chain**
- *End state:* rhel02 shows identical containment posture to rhel01, reached through Scan→Splunk→EDA→workflow.
- *Mechanism:* Launch `DEFEND - Scan System` `limit=rhel02`; optionally force the Splunk saved search to fire (Splunk REST) to avoid waiting for the 1-min cron; wait for the auto-triggered `Vulnerability Containment` job on rhel02.
- *Verify:* rhel02 `eth0` in `internal-only`; Rule Audit shows a matched event. Fallback: if the EDA path is flaky in an unattended run, launch the containment workflow directly against rhel02 (document this as a deviation).

### Module 2 — CONTAIN

**M2-A — backup markers present**
- *End state:* `/var/log/last-backup-timestamp` exists on rhel01 and rhel02.
- *Mechanism:* `ansible.builtin.file` touch on both app servers.
- *Verify:* File stat exists.

**M2-B — pre-patch-check playbook (NO ACTION — verified)**
- *Verified §0:* The `CONTAIN - Pre-Patch Check` job template already points at the complete
  solution `lab/playbooks/contain/pre-patch-check.yml`. The "uncomment the task" step operates on
  the decoy `-exercise.yml`, which nothing runs. **No commit/sync needed for the solve.** Keep this
  entry only to document why it's a deliberate no-op.
- *Verify:* `CONTAIN - Pre-Patch Check` runs green (covered by M2-E).

**M2-C — Policy-Gated Patching workflow nodes built**
- *End state:* 5-node workflow: Pre-Patch Check → Approval (`Approve Patch Application`, 900s) → Patch System → Post-Patch Verify → Report Compliance.
- *Verified §0:* The workflow is created at deploy time **as an empty shell**; its node-building
  tasks in `configure-aap.yml` are tagged `patching_workflow` **and `never`**, so they don't run.
- *Mechanism (recommended shortcut):* On `control`, re-run the shipped config with the tag:
  `ansible-playbook lab/setup/configure-aap.yml -i lab/inventory/workshop.yml --tags patching_workflow -e controller_oauth_token_override=<token>` — this builds exactly the intended nodes using the repo's own definitions (no drift). *Alternative:* replicate the five `workflow_job_template_node` tasks in the solve. **Recommend the tag shortcut.**
- *Verify:* Workflow has 5 nodes with the approval node between precheck and patch.

**M2-D — execution policy (separation of duties) configured**
- *End state:* AAP OPA policy setting → server `192.168.1.11`; org `Default` enforcement path `aap/gateway/decision`.
- *Verified §0:* `dcc-execution-policy.rego` is loaded into OPA at deploy, but the AAP-side wiring
  is genuinely learner-done and **not** injected. `security_engineer` already has password
  `ansible123!` from deploy — **no password step needed** (contradicts lab guide M2 Ex4).
- *Mechanism:* Controller settings API for OPA hostname; org update API (gateway) for enforcement path `aap/gateway/decision`.
- *Verify:* Launch as `admin` is **denied**; launch as `security_engineer` is allowed.

**M2-E — patch applied end-to-end**
- *End state:* `httpd-2.4.62-1.el9`+ on rhel01; CVE resolved; compliance report in `/tmp/compliance-reports` and on portal; `set_stats` artifacts recorded.
- *Mechanism:* Launch `Policy-Gated Patching` **as `security_engineer`** (separate API token); auto-approve the workflow approval node via the workflow approvals API; poll to completion.
- *Verify:* `rpm -q httpd`; `yum updateinfo` no longer lists the CVE; report file dated today exists.

> **Approval automation is the trickiest piece** — the solve must approve its own workflow via the
> `workflow_approvals/{id}/approve/` endpoint after polling for the pending node. Call out timeout handling.

### Module 3 — COMPLY

**M3-A — full compliance pipeline run**
- *End state:* Pre-audit → CIS harden → post-audit (all pass) → report → container built → scanned clean → pushed to `localhost:5000` (`dcc-httpd`).
- *Mechanism:* **Preferred single action:** launch the `Compliance and Hardening` workflow (7 nodes, On-Success chain) and wait. This subsumes M3 exercises 2–7.
- *Verify:*
  - SSH hardening (`sshd -T`): permitrootlogin no, x11forwarding no, maxauthtries 4, clientaliveinterval 300.
  - File perms 644/644/000/000 on passwd/group/shadow/gshadow.
  - Kernel: accept_redirects=0, send_redirects=0, randomize_va_space=2.
  - rpcbind/avahi disabled.
  - Registry catalog lists `dcc-httpd`; image labels carry advisory metadata; scan shows CVE absent.
  - post-audit report shows all 13 controls passing.

**M3-B — (optional) individual template path**
- If per-step verification is wanted, launch the six COMPLY job templates individually with `audit_phase` extra-var (`pre`/`post`) instead of the workflow. Mutually exclusive with M3-A.

---

## 6. Cross-cutting requirements

- **Idempotency:** Re-running the solve on an already-solved lab should succeed or no-op, not error. Firewall/patch/container states are naturally convergent; workflow launches are not — guard with "already in end state?" checks (e.g., skip patch launch if httpd already patched). Preflight §4.3 "not already solved" checks become warnings, not hard fails, when `force_resolve=true`.
- **Waiting/polling:** Every launch waits for terminal status with a bounded timeout; surface job IDs and failure output.
- **Secrets:** Reuse `config/secrets.yaml` + `BASTION_*` env pattern from `setup-automation/`. Never echo the controller password (the validation scripts already `set +x` for this reason).
- **Inventory:** Reuse the `add_host` block from `setup-automation/main.yml` (control/central/rhel01/rhel02 with `eth1`/192.168.1.x).
- **Reporting:** Emit a final PASS/FAIL summary per module, matching the `fail_validation` output convention already used.

---

## 7. Open questions / decisions

**Resolved by §0 upstream verification:**
- ✅ *Workflows pre-created vs. learner-built:* `Vulnerability Containment` and `Compliance and Hardening` are fully built; `Policy-Gated Patching` is an empty shell (nodes tagged `never`) → M2-C is a real task with a tag-based shortcut.
- ✅ *pre-patch playbook edit:* not needed — the job template already runs the solution file.
- ✅ *security_engineer password:* already set at deploy → no password step in solve.
- ✅ *OPA policies loaded:* all three `.rego` mounted into OPA at deploy → preflight checks valid.
- ✅ *Version/name constants:* confirmed from `vars/workshop.yml` (§0).
- ✅ *EDA rulebook discovery path (was Q2):* confirmed live (§0.1) — solve must commit to `extensions/eda/rulebooks/` and re-sync; nothing is auto-discovered from the shipped `lab/extensions/eda/` path.
- ✅ *Live topology & resource presence:* confirmed (§0.1).

**Still open — need a decision before implementation:**
1. **Solve mechanism — confirm API-driven.** Drive AAP Controller/EDA APIs to launch shipped templates + the tag-shortcut for M2-C. Host-direct alternative is out of scope. **Recommendation: API-driven.**
2. **EDA end-to-end vs. shortcut for M1-E.** Prove the full Splunk→EDA→AAP chain (realistic, flaky unattended) or accept a direct `Vulnerability Containment` launch against rhel02 as the sanctioned solve path? **Recommendation: attempt the chain with a bounded wait, fall back to direct launch and record the deviation.**
3. ✅ *Workflow approval automation (was open):* verified live (§0.2) — `POST /workflow_approvals/{id}/approve/` as `security_engineer` returns 204 and approves. No longer open.
4. ✅ *Where the solve lives (was open):* decided by the harness (§0.2) — the solve is per-module `runtime-automation/module-0{1,2,3}-*/solve-central.sh`, consumed by `qa-automation/e2e.yml`. No new tree.

---

## 8. Deliverable structure (revised per §0.2 — harness-driven)

The solve plugs into the existing e2e harness as per-module `solve-central.sh` scripts (bash + curl,
run on `central`), mirroring the shipped `validation-central.sh` scripts:

```
runtime-automation/
  module-01-defend/
    solve-central.sh            # NEW — §5 M1-A..E via Controller/EDA APIs + Gitea commit
    validation-central.sh       # exists
  module-02-contain/
    solve-central.sh            # NEW — §5 M2-A,C,D,E (M2-B is a no-op, §5)
    validation-central.sh       # exists
  module-03-comply/
    solve-central.sh            # NEW — §5 M3-A (launch Compliance and Hardening workflow)
    validation-central.sh       # exists
```

`qa-automation/e2e.yml` then runs solve→validation per module automatically (already wired).
A separate preflight (§4) can run as a standalone play or as an early guard inside
`module-01-defend/solve-central.sh`.

**Reuse rules:**
- Template/workflow names: copy verbatim from the three `validation-central.sh` files (already authoritative).
- API base + auth + `fail_validation` fallback: copy the header block from `validation-central.sh`.
- M2-C node build: shell out to the shipped config with `--tags patching_workflow` on `control`, or replicate the node POSTs — either way, no drift.
- M2-E approval: poll `/workflow_approvals/?status=pending` then POST `.../approve/` as `security_engineer` (verified §0.2).

---

## 9. Out of scope

- Provisioning the lab (owned by `setup-automation/`).
- Rewriting or replacing the shipped DCC playbooks/job templates.
- Host-direct reimplementation of containment/patch/hardening logic.
- Any change to lab guide content.
