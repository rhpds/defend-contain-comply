# DCC QA Solve — Implementation Plan (qa-automation/tasks/)

Implementation blueprint for automating the *Defend, Contain, Comply* lab solve as
Ansible task files under `qa-automation/tasks/`, wired into `qa-automation/e2e.yml`
and `qa-automation/healthcheck.yml`.

This plan implements the end-states agreed in [SOLVE_SCOPE.md](SOLVE_SCOPE.md) §5.
It **supersedes** SOLVE_SCOPE.md §8 (which placed solve logic in
`runtime-automation/module-XX/solve-central.sh`). Per the current constraint, the
solve lives entirely in `qa-automation/`.

---

## 1. Constraints (hard requirements)

1. **Solve logic lives in `qa-automation/tasks/`** as Ansible task files — not shell
   scripts, not new top-level trees.
2. **`e2e.yml` and `healthcheck.yml` are the only two playbooks modified** to consume
   the new tasks.
3. **`setup-automation/` and `runtime-automation/` are NOT modified** — they are
   learner-facing. We may *read from* and *execute* their existing artifacts
   (e.g. the shipped `runtime-automation/<module>/validation-central.sh` scripts,
   and the shipped rulebook under `lab/extensions/eda/`), but we change nothing in them.
4. **e2e is destructive and completes the lab** — run only for capacity planning /
   testing. **healthcheck is non-destructive** and polled periodically.
5. **Live-env discipline:** all `oc` verification stays read-only; no controller
   password is ever echoed (mirror the `set +x` convention already in the validation
   scripts).

> Filename note: the request says `healthcheck.yaml`; the file on disk is
> `qa-automation/healthcheck.yml`. This plan targets the existing `.yml` file.

---

## 2. Design principles

- **`ansible.builtin` only.** The QA runner's execution environment already runs
  `healthcheck.yml` with `uri`, `wait_for`, `systemd`, and `command`/`podman`.
  Every solve task is built from `ansible.builtin.uri` (AAP/EDA/OPA/Gitea/Splunk
  REST), `ansible.builtin.file`/`command` (host-direct), and `ansible.builtin.assert`.
  No new collections, so no EE rebuild.
- **API-driven solve** (SOLVE_SCOPE §7 decision 1). Drive the *shipped* job/workflow
  templates via the Controller/EDA APIs rather than reimplementing lab logic. The one
  build step (M2-C nodes) reuses the repo's own definitions via a tag shortcut.
- **Runs on `central` (the bastion).** `central` resolves `control`, `rhel01`,
  `rhel02` (via `/etc/hosts` from setup) and reaches OPA (`localhost:8181`) and
  Splunk mgmt (`localhost:8089`) locally. Same host context `healthcheck.yml`
  already uses.
- **Basic auth, no token dance.** Use `url_username`/`url_password` +
  `force_basic_auth: true` on `uri`. `admin`/`ansible123!` for admin actions;
  `security_engineer`/`ansible123!` for the separation-of-duties path (already set at
  deploy — SOLVE_SCOPE §5 M2-D). Credentials come from the `BASTION_*` env +
  `config/secrets.yaml` pattern already used; never logged (`no_log: true` on auth tasks).
- **Idempotent + convergent** (SOLVE_SCOPE §6). Every task guards on "already in end
  state?" before launching: skip patch if `httpd` already patched, skip node-build if
  the workflow already has 5 nodes, `creates:`-guard host-direct steps. Re-running a
  solved lab no-ops rather than errors.
- **Bounded waits.** Every template/workflow launch polls to a terminal status with a
  timeout; job IDs and failing output are surfaced in the final summary.
- **Reuse shipped validation.** After each module's solve tasks run, e2e still calls
  the existing `tasks/run_script.yml` with `stage_name=validation`, which executes the
  unmodified `runtime-automation/<module>/validation-central.sh`. Solve does the work;
  the shipped script confirms it.

---

## 3. New files under `qa-automation/tasks/`

```
qa-automation/
├── e2e.yml                     (MODIFIED)
├── healthcheck.yml             (MODIFIED)
├── vars/
│   └── solve.yml               (NEW — shared constants)
└── tasks/
    ├── run_script.yml          (UNCHANGED — reused for validation stage)
    ├── _launch_job.yml         (NEW — reusable: launch job template + poll)
    ├── _launch_workflow.yml    (NEW — reusable: launch workflow + auto-approve + poll)
    ├── preflight.yml           (NEW — pre-solve environment gate; SOLVE_SCOPE §4)
    ├── solve_module_01_defend.yml   (NEW — M1-A..E)
    ├── solve_module_02_contain.yml  (NEW — M2-A, C, D, E)
    ├── solve_module_03_comply.yml   (NEW — M3-A)
    └── verify_services.yml     (NEW — health checks refactored out of healthcheck.yml)
```

### 3.1 `vars/solve.yml` — shared constants

Single source of truth, sourced from the verified upstream `lab/setup/vars/workshop.yml`
and live checks (SOLVE_SCOPE §0). Holds:

- API bases: `controller_api: https://control/api/controller/v2`,
  `eda_api: https://control/api/eda/v1`, `opa_url: http://localhost:8181`,
  `splunk_mgmt: https://localhost:8089`, `gitea_api: <resolved gitea base>/api/v1`.
- Org / inventory / user IDs: org `1`, inventory `2`, `security_engineer` user `3`
  (confirmed live, §0.1/§0.2).
- Names: the 16 job-template names, 3 workflow names
  (`Vulnerability Containment`, `Policy-Gated Patching`, `Compliance and Hardening`),
  EDA project name `Defend, Contain, Comply`, credential `Splunk EDA Token`,
  event stream `Splunk EDA`, activation `DCC CVE Alert Responder`.
- Version constants: patched `httpd-2.4.62-1.el9`, `target_cve` CVE-2024-38476,
  advisory RHSA-2024:5138.
- Tunables: `solve_job_timeout` (default 900s), `force_resolve` (default `false`),
  `eda_chain_mode` (`chain`|`direct`, default `chain` with direct fallback — §5 M1-E).

Auth values are **not** stored here — they resolve from env/`secrets.yaml` at play level.

### 3.2 `_launch_job.yml` — reusable job-template launcher

Params: `jt_name`, optional `limit`, optional `extra_vars`, optional `as_user`
(default admin). Steps:
1. `uri GET .../job_templates/?name=<jt_name>` → resolve id (basic auth, `no_log`).
2. `uri POST .../job_templates/{id}/launch/` with `limit`/`extra_vars`.
3. Poll `GET .../jobs/{id}/` until `status in [successful, failed, error, canceled]`
   (`until`/`retries`/`delay`, bounded by `solve_job_timeout`).
4. `assert status == successful`; on failure, pull `stdout` (fmt=txt) into the summary.

### 3.3 `_launch_workflow.yml` — reusable workflow launcher w/ approval

Params: `wf_name`, optional `limit`/`extra_vars`, `as_user`, `auto_approve` (bool).
Steps:
1. Resolve workflow_job_template id by name.
2. `POST .../workflow_job_templates/{id}/launch/` (as `as_user` — used as
   `security_engineer` for M2-E).
3. If `auto_approve`: poll `GET .../workflow_jobs/{id}/workflow_nodes/` for a node in
   `pending` approval state, then
   `POST .../workflow_approvals/{approval_id}/approve/` **as `security_engineer`**
   (verified 204 live, §0.2). Handle the approval timeout window (node `timeout` 900s).
4. Poll the workflow job to terminal status; assert successful.

---

## 4. Per-module solve task files

Each maps directly to SOLVE_SCOPE §5. All guard for idempotency.

### 4.1 `solve_module_01_defend.yml` (M1-A..E)

- **M1-A** — `_launch_workflow.yml wf_name="Vulnerability Containment" limit=rhel01`.
  Guard: skip if rhel01 `eth0` already in `internal-only` zone.
- **M1-B** — Commit `splunk-cve-alert.yml` to the Gitea repo at the **discoverable**
  path `extensions/eda/rulebooks/splunk-cve-alert.yml` (content copied from the shipped
  solution `lab/extensions/eda/splunk-cve-alert.yml`), via
  `uri PUT/POST .../repos/gitea/defend-contain-comply/contents/...`. Then
  `POST /api/eda/v1/projects/{id}/sync/` and poll `import_state=completed`.
  Guard: skip commit if the file already exists at that path (check
  `GET .../contents/...`, tolerate 404). *This is required work* — EDA discovers 0
  rulebooks otherwise (§0.1). **Gitea reachability from `central` is the one item to
  confirm on first run** (see §8 risks).
- **M1-C** — Create EDA credential `Splunk EDA Token` (token `ansibleiscool`, header
  `Authorization`), event stream `Splunk EDA`, and rulebook activation
  `DCC CVE Alert Responder`; configure the Splunk add-on webhook `Splunk2EDA` via
  Splunk REST (mgmt 8089) pointing at the event-stream endpoint (`192.168.1.10`).
  Poll activation status → `running`. Each create is guarded (GET-by-name first).
- **M1-D** — `_launch_job.yml jt_name="DEFEND - Deploy Application" limit=rhel02`.
  Guard: skip if rhel02 portal already answers.
- **M1-E — layered verification (decided 2026-09-29).** Prove the chain deterministically
  rather than waiting on Splunk's cron:
  1. **Wire + deploy the target:** `_launch_job.yml jt_name="DEFEND - Deploy Application"`
     already done in M1-D; ensure the EDA resources from M1-C exist.
  2. **Static config assert (no timing):** event stream `Splunk EDA` exists; activation
     `DCC CVE Alert Responder` status == `running` (poll to Running with a bounded wait —
     newly created activations take time to boot); Splunk `DCC` environment present with
     `webhook_endpoint` == the event-stream receptor URL; `/api/eda/v1/rulebooks/` ≥ 1.
  3. **Deterministic trigger:** `POST` a synthetic event straight at the EDA event-stream
     receptor URL (token auth) with a payload whose `search_name` matches
     `search("CVE Alert")` and carries the affected host = `rhel02`. This exercises
     EDA rulebook → AAP workflow launch without Splunk indexing lag or the 1-min cron.
     *(Read the shipped rulebook `lab/extensions/eda/splunk-cve-alert.yml` to copy the
     exact field paths the condition/`job_args.limit` expect.)*
  4. **Verify by causal audit trail:** confirm EDA Rule Audit
     (`/api/eda/v1/audit-rules/`) shows a matched event, and the controller shows a
     `Vulnerability Containment` job with `launch_type != manual` and `limit=rhel02`.
     Then confirm rhel02 posture (`eth0` in `internal-only`).
  - **Last-resort fallback** (`eda_chain_mode=direct`, or steps 2–4 fail after their
    bounded timeout): launch `Vulnerability Containment` directly on rhel02 so the
    destructive e2e still reaches the "lab complete" end-state, and record the deviation
    prominently in the summary. The fallback guarantees state; it does **not** count as
    the chain passing.
  - Note: these assertions live only in e2e (post-solve) — they cannot move into the
    periodic `healthcheck`, since the EDA resources don't exist on an un-solved lab.

### 4.2 `solve_module_02_contain.yml` (M2-A, C, D, E)

- **M2-A** — touch `/var/log/last-backup-timestamp` on rhel01 **and** rhel02. These
  are the only host-direct mutations; they require rhel01/rhel02 in inventory
  (see §5.1). `ansible.builtin.file state=touch` with a `creates`-style guard.
- **M2-B** — *no-op* (documented). The `CONTAIN - Pre-Patch Check` template already
  runs the solution file; the "uncomment" step targets a decoy (§0). No task.
- **M2-C** — Build the 5 `Policy-Gated Patching` nodes. The workflow ships as an empty
  shell (node tasks tagged `never`). **Recommended mechanism:** reproduce the shipped
  node definitions via the Controller `workflow_job_template_nodes` API from within
  this task file (Pre-Patch Check → Approval `Approve Patch Application` 900s →
  Patch System → Post-Patch Verify → Report Compliance).
  Guard: skip if the workflow already has 5 nodes.
  > Note: SOLVE_SCOPE §5 M2-C's tag shortcut
  > (`ansible-playbook configure-aap.yml --tags patching_workflow`) is a
  > `setup-automation`/`lab` artifact. Because we must not modify those trees and want
  > the build driven from `qa-automation/`, the API-node-build is the primary path
  > here; the tag shortcut remains a documented manual alternative.
- **M2-D** — Set Controller OPA server `192.168.1.11` (settings API) and org `Default`
  enforcement path `aap/gateway/decision` (gateway/org API). No password step needed
  (`security_engineer` already `ansible123!`). Guard: skip if already set.
- **M2-E** — `_launch_workflow.yml wf_name="Policy-Gated Patching" limit=rhel01
  as_user=security_engineer auto_approve=true`. Ensure the OPA maintenance window
  passes first (launch `CONTAIN - Update Maintenance Window` if the window gate would
  fail). Guard: skip if `rhel01 rpm -q httpd` already reports `2.4.62-1.el9`+.

### 4.3 `solve_module_03_comply.yml` (M3-A)

- **M3-A** — `_launch_workflow.yml wf_name="Compliance and Hardening"` (7-node
  On-Success chain: Audit Pre → CIS Harden → Audit Post → Report → Build → Scan →
  Push). This single launch subsumes COMPLY exercises 2–7. Guard: skip harden portion
  if post-audit already all-pass (best-effort — the workflow is convergent anyway).

### 4.4 `preflight.yml` (SOLVE_SCOPE §4 — pre-solve gate, e2e only)

Runs once before any solve module. Asserts: connectivity to control/OPA/Gitea/Splunk;
AAP API reachable; the expected shipped resources present (16 templates, 3 workflows,
EDA project synced, 3 OPA policies loaded); baseline "not already solved" checks. Under
`force_resolve=true` the "already solved" checks downgrade to warnings (§6).

---

## 5. `e2e.yml` modifications

Current `e2e.yml`: play 1 adds the bastion; play 2 (`hosts: all:!localhost`,
`become: true`) loops `modules × [solve, validation]` through `tasks/run_script.yml` —
which today can only run *shell* scripts, and no solve scripts exist.

**Changes:**

1. **Extend inventory (play 1).** Also `add_host` `rhel01` and `rhel02` (reachable
   from `central`) so M2-A backup markers can be file-touched directly. Reuse the
   host/IP facts from `setup-automation/main.yml` (read-only reference; not modified).
2. **Load vars.** Add `vars_files: [vars/solve.yml]` and resolve auth from
   `BASTION_*` env / `config/secrets.yaml` at play level.
3. **Replace the solve stage.** Drop `solve` from the `product()` loop. Instead, run
   an explicit ordered sequence on `central`:
   ```
   include_tasks: tasks/preflight.yml
   include_tasks: tasks/solve_module_01_defend.yml   → run_script.yml (validation, module-01)
   include_tasks: tasks/solve_module_02_contain.yml  → run_script.yml (validation, module-02)
   include_tasks: tasks/solve_module_03_comply.yml   → run_script.yml (validation, module-03)
   ```
   Validation still flows through the **unchanged** `tasks/run_script.yml`
   (`stage_name=validation`), executing the shipped `runtime-automation/<module>/
   validation-central.sh`. Module order still derives from `ui-config.yml`.
4. **Final summary.** Emit a per-module PASS/FAIL block (job IDs, deviations such as
   the M1-E direct-launch fallback), matching the `fail_validation` output convention.

Net effect: e2e *solves* (new tasks) then *validates* (shipped scripts) — closing the
gap where e2e previously validated but never solved.

### 5.1 Inventory & host-task pattern (decided 2026-09-29)

- **Central play + `delegate_to`.** The solve play targets `central` only. Tasks that
  mutate rhel01/rhel02 (M2-A backup markers) use `delegate_to: <host>`; rhel01/rhel02
  are added to inventory by `e2e.yml` play 1 but the play body still runs once on
  `central`, so the API/`uri` tasks are naturally single-run (no `run_once` noise).
- **Cross-module OPA dependency (verified live).** `Policy-Gated Patching` (M2-E) runs
  `CONTAIN - Pre-Patch Check` across the **whole inventory** (rhel01+rhel02) — the WFJT
  has `ask_limit_on_launch=false`, so a launch-time `limit` is rejected and ignored.
  The OPA patch policy then blocks any host missing a backup marker or with its target
  service inactive. Therefore M2-E only passes after **M2-A** (backups on both hosts)
  and **M1-D** (deploy app on rhel02 → service active) have run. This is why the solve
  must execute in module order 1 → 2 → 3, and why `_launch_workflow.yml`'s approve+poll
  path can only be exercised end-to-end once module 1 + M2-A state exists.
- **`_launch_workflow.yml` prompt gating.** The helper only sends `limit`/`extra_vars`
  when the target WFJT has the matching `ask_*_on_launch` flag; otherwise it warns and
  omits them (avoids the HTTP 400 "not configured to prompt on launch").

---

## 6. `healthcheck.yml` modifications

Keep healthcheck **non-destructive and fast** (it is polled periodically). Changes are
a light refactor plus optional resource-presence checks:

1. **Refactor existing service checks into `tasks/verify_services.yml`** (containers
   splunk/opa, `dcc-errata-repo` systemd, ports, AAP ping, OPA health) and
   `include_tasks` it from `healthcheck.yml`. Behavior unchanged; now reusable.
2. **Optional read-only presence checks** (additive, still non-destructive): AAP API
   reachable and the 3 shipped workflows present; OPA has all 3 policies loaded. These
   overlap `preflight.yml` but stay strictly read-only — no launches, no commits, no
   settings writes. Failures roll into the existing `hc_failures` assert.

`healthcheck.yml` never includes any `solve_module_*` task.

---

## 7. Mapping to SOLVE_SCOPE §5

| Scope item | Task file | Mechanism |
|---|---|---|
| M1-A | solve_module_01_defend | launch `Vulnerability Containment` (rhel01) |
| M1-B | solve_module_01_defend | Gitea commit rulebook + EDA project sync |
| M1-C | solve_module_01_defend | EDA cred/stream/activation + Splunk add-on |
| M1-D | solve_module_01_defend | launch `DEFEND - Deploy Application` (rhel02) |
| M1-E | solve_module_01_defend | layered: config assert → synthetic event inject → Rule Audit verify (fallback: direct launch) |
| M2-A | solve_module_02_contain | file touch backup markers rhel01+rhel02 |
| M2-B | — | documented no-op |
| M2-C | solve_module_02_contain | build 5 workflow nodes via API |
| M2-D | solve_module_02_contain | OPA settings + org enforcement path |
| M2-E | solve_module_02_contain | launch `Policy-Gated Patching` as security_engineer + auto-approve |
| M3-A | solve_module_03_comply | launch `Compliance and Hardening` |
| §4 preflight | preflight.yml | pre-solve gate (e2e) |
| §6 reporting | e2e.yml summary | per-module PASS/FAIL |

---

## 8. Risks — status after live verification (2026-09-29, sandbox-j9lwg-zt-ansiblebu)

All pre-implementation unknowns from the first draft were checked against the live dev
environment. Results:

1. ✅ **Gitea reachable from `central` — RESOLVED.** `central` resolves `gitea` via the
   cluster DNS search domain (`gitea.<ns>.svc.cluster.local` → 172.30.25.124) and
   `curl http://gitea:3000/api/v1/version` returns HTTP 200. M1-B commits directly from
   `central`; no route/IP fallback needed. `gitea_api` = `http://gitea:3000/api/v1`.
2. ✅ **Splunk add-on REST config — RESOLVED (was highest risk).** The add-on
   `ansible_addon_for_splunk` exposes a create/edit/list/remove REST handler
   `ansible_addon_for_splunk_environment`. M1-C `POST`s to
   `/servicesNS/nobody/ansible_addon_for_splunk/ansible_addon_for_splunk_environment`
   with the field set in Appendix A.5. No `DCC` environment exists yet (add-on `local/`
   is empty) → genuinely learner work. The EDA direct-launch fallback for M1-E stays as
   a safety net, but the Splunk path is now scriptable.
3. ✅ **rhel01/rhel02 reachable — RESOLVED.** The QA runner SSHes to each VM by name
   (`central`/`control`/`rhel01`/`rhel02` all resolve to VM IPs); from `central` the
   peers are in `/etc/hosts` on 192.168.1.13/.14. `add_host` for rhel01/rhel02 with
   `ansible_ssh_host=rhel01|rhel02`, user `rhel`, reusing `BASTION_PASSWORD`, works.
4. ✅ **Approval timing (M2-E) — RESOLVED.** `security_engineer` (id 3) already holds
   **Admin + Execute + Approve** on `Policy-Gated Patching` (27) and Admin on org
   `Default` — no role grants needed. Approval endpoint verified 204 (§0.2). Node
   timeout 900s; auto-approve poll runs inside it.
5. ⚠️ **Idempotency — still to validate at implementation.** Exercise both a fresh
   deploy and a re-run; `force_resolve=true` path must end green on an already-solved lab.
6. ⚠️ **EDA event-stream receptor URL (M1-C).** The webhook endpoint fed to the Splunk
   `Splunk2EDA` environment is generated when the event stream is created — read it back
   from the event-stream create response at runtime rather than hard-coding it.

## 9. Build & test methodology — one Ansible task at a time (mandatory)

**The unit of iteration is a single Ansible task, not a task file.** Write one task
(one module invocation), run it against the live dev environment, confirm it does exactly
what it should, and only then write the next task. Files are grown task-by-task, never
authored whole. Writing a complete file up front reliably introduces multiple errors at
once (auth quirks, wrong response keys, filter/`loop` mistakes, timing, idempotency) that
then mask each other; adding and proving one task at a time keeps every failure isolated,
obvious, and cheap to fix. Every task is verified against `sandbox-j9lwg-zt-ansiblebu`
(or a freshly deployed equivalent) before the next task is written.

### 9.1 Per-*task* micro-loop
This is the core discipline. For each individual task added to a file:
1. **Write exactly one task** (or a single register + its immediate `assert`/`debug`
   pair when a value must be inspected).
2. **Run just that task** — append it to the file-in-progress and execute the file on
   `central` (earlier already-passing tasks stay in place; new task runs last). Use a
   thin scratch wrapper play if the file isn't includable standalone yet.
3. **Inspect the real result:** print/register the module return and confirm the actual
   response shape and values — do not assume the API/module returned what the docs imply.
   Pin down the exact keys (e.g. `.json.results[0].id`, `.status`, EDA pagination) from
   live output before referencing them in the next task.
4. **Verify the end-state independently** where the task mutates state — a read-only
   API/`oc`/host check separate from the task's own `changed/ok`.
5. **Re-run** — the task (and the growing file) must stay green and idempotent.
6. **Commit the task mentally as "known-good," then write the next one.** If it fails,
   fix it before adding anything else — never stack an unverified task on an unverified one.

### 9.2 Per-*file* checkpoint
Once a file's tasks are all individually proven, do a whole-file pass:
`ansible-lint` + `--syntax-check`, run the complete file in isolation, verify end-state,
re-run for idempotency. Then move to the next file in the build order below.

### 9.3 Destructive vs. safe — file build order, chosen to defer irreversible steps
Some solve tasks irreversibly consume the lab (contain, patch, harden). Build and test
the **non-destructive and additive** tasks first so the harness is proven before the
environment gets consumed; cluster the irreversible ones last and expect to **deploy a
fresh environment** for the final full-chain pass.

| # | Task | Isolation test target | Destructive? | Notes |
|---|------|------------------------|--------------|-------|
| 1 | `vars/solve.yml` + auth smoke | `GET ping`, list templates | No | proves creds/paths only |
| 2 | `_launch_job.yml` | launch **Demo Job Template (7)** | No | harmless template = pure launcher test |
| 3 | `verify_services.yml` | run standalone | No | read-only health checks |
| 4 | `preflight.yml` | run standalone | No | read-only presence/baseline |
| 5 | `_launch_workflow.yml` (+approval) | throwaway workflow (as in §0.2) | No | test launch+approve mechanics, then delete |
| 6 | M2-C node build (in `solve_module_02`) | build nodes on WFJT 27 | Additive | reversible: delete nodes to retest |
| 7 | M2-D policy wiring | set `OPA_HOST`/`opa_query_path` | Reversible | revert to `''`/`None` to retest |
| 8 | M1-B rulebook commit + sync | commit + `projects/1/sync` | Additive | re-runnable; guarded on file exists |
| 9 | M1-C EDA cred/stream/activation + Splunk env | create resources | Additive | guarded GET-by-name; activation→Running |
| 10 | M2-A backup markers | touch on rhel01/rhel02 | Low | `creates`-guarded file touch |
| 11 | **M1-A** contain rhel01 | launch `Vulnerability Containment` | **Yes** | consumes rhel01 posture |
| 12 | **M1-D** deploy rhel02 | launch `Deploy Application` | Mostly idempotent | redeployable |
| 13 | **M1-E** chain (inject+audit) | synthetic event → Rule Audit | **Yes** | consumes rhel02 posture |
| 14 | **M2-E** patch rhel01 | `Policy-Gated Patching` + approve | **Yes** | irreversible patch |
| 15 | **M3-A** harden+build+push | `Compliance and Hardening` | **Yes** | irreversible hardening |

Tasks 1–10 are safe to iterate repeatedly on one environment. Tasks 11–15 change lab
end-state; test them on a fresh deploy (or accept that the environment is consumed and
redeploy for the next destructive task if a mid-chain failure needs a clean retry).

### 9.4 Integration passes (after all tasks pass individually)
1. **Wire `e2e.yml`** and run the full ordered solve+validation on a **fresh deploy** —
   the destructive, "renders the lab complete" run — and confirm all three module
   validations pass.
2. **Idempotency pass:** re-run `e2e.yml` on the just-solved lab; `force_resolve` path
   must end green.
3. **Wire `healthcheck.yml`**, run it, confirm the refactor is green (baseline: central
   ok, 0 failed) and non-destructive.
4. **Harness pass:** trigger via the Showroom endpoints
   (`/stream/qa/healthcheck`, `/stream/qa/e2e`) to confirm end-to-end wiring.

## 10. Out of scope (unchanged from SOLVE_SCOPE §9)

Provisioning (setup-automation), rewriting shipped playbooks/templates, host-direct
reimplementation of lab logic, any lab-guide content change, and — added here — any
edit to `setup-automation/` or `runtime-automation/`.

---

## Appendix A — Verified environment data (dev, 2026-09-29)

Source: read-only queries against `sandbox-j9lwg-zt-ansiblebu` on `ocpvdev01`. These
values populate `vars/solve.yml`. Names/IDs are stable per deploy of this catalog item;
re-verify IDs on a fresh deploy (resolve-by-name in tasks rather than trusting IDs).

### A.1 Access paths (as the solve runs — from `central`)
| Target | From central | Auth |
|---|---|---|
| Controller / EDA / Gateway API | `https://control` (443) → `/api/controller/v2`, `/api/eda/v1`, `/api/gateway/v1` | basic `admin` / `security_engineer` |
| OPA | `http://localhost:8181` (podman container on central) | none |
| Splunk mgmt | `https://localhost:8089` (podman container on central) | basic `admin` |
| Gitea | `http://gitea:3000` → `/api/v1` (cluster DNS) | basic `gitea` |
| rhel01 / rhel02 | ssh by name (192.168.1.13/.14 in `/etc/hosts`) | `rhel` + `BASTION_PASSWORD` |
| central python | `/usr/libexec/platform-python` (3.9) | — |

Controller version 4.7.4. Password for all four services is the shared lab constant
(never echo it; `no_log` on auth tasks).

### A.2 Controller object IDs
- Org `Default` = **1**; Inventory `DCC Workshop` = **2**; user `security_engineer` = **3**.
- `security_engineer` roles: Admin+Execute+Approve on WFJT 27, Admin on org 1.
- Job templates: Scan System **10**, Deploy Application **9**, Contain Service **11**,
  Harden Posture **12**, Restore Containment **13**, Verify Security Posture **14**;
  Pre-Patch Check **15**, Patch System **16**, Post-Patch Verify **17**,
  Report Compliance **18**, Update Maintenance Window **19**; Compliance Audit **20**,
  CIS Harden **21**, Compliance Report **22**, Build Container **23**, Scan Image **24**,
  Push to Registry **25**.
- Workflows: Vulnerability Containment **26** (3 nodes, built), Policy-Gated Patching
  **27** (**0 nodes** — M2-C real), Compliance and Hardening **28** (7 nodes, built).

### A.3 M2-C node build (target for WFJT 27)
Linear On-Success chain, mirroring WFJT 26's structure:
`Pre-Patch Check (15)` → *approval* `Approve Patch Application` (timeout 900s) →
`Patch System (16)` → `Post-Patch Verify (17)` → `Report Compliance (18)`.
Build via `POST /api/controller/v2/workflow_job_templates/27/workflow_nodes/`
(+ `/approval_nodes/` for the approval) and link with each node's
`success_nodes`. Guard: skip if node count already 5.

### A.4 M2-D policy wiring
- Controller settings (`PATCH /api/controller/v2/settings/all/`): `OPA_HOST` `''` →
  `192.168.1.11`; `OPA_PORT` already 8181; `OPA_SSL` already `false`.
- Controller org 1 (`PATCH /api/controller/v2/organizations/1/`): field
  **`opa_query_path`** `None` → `aap/gateway/decision`.
- OPA execution policy package is `aap.gateway`; `GET /v1/data/aap/gateway/decision`
  returns HTTP 200 `{"allowed":...,"violations":[]}`. (Compliance = `dcc.compliance`;
  patch = `dcc.patch_policy` — all three `.rego` loaded.)

### A.5 M1-C EDA + Splunk wiring
- EDA project `Defend, Contain, Comply` = **id 1**, git
  `http://gitea:3000/gitea/defend-contain-comply.git`, `import_state=completed`,
  **0 rulebooks** discovered. Re-sync: `POST /api/eda/v1/projects/1/sync/`.
- Default Decision Environment = **id 1**. eda-credential `DCC Controller Token` =
  **id 4** (for the activation). credential-type `Token Event Stream` = **id 8** (kind
  `token`) — used to create `Splunk EDA Token` (token `ansibleiscool`, header
  `Authorization`). event-streams = 0, activations = 0.
- Create order: Token Event Stream credential → event stream `Splunk EDA` (read back its
  receptor URL) → Splunk environment → activation `DCC CVE Alert Responder`
  (project 1, rulebook `splunk-cve-alert.yml`, DE 1, eda-credential 4, event stream `Splunk EDA`).
- **Splunk environment** — `POST /servicesNS/nobody/ansible_addon_for_splunk/ansible_addon_for_splunk_environment`
  (form-encoded), fields:
  `name=Splunk2EDA`, `integration_type=webhook`, `environment=DCC`,
  `webhook_endpoint=<event-stream receptor URL>`, `auth_type=token`,
  `token=ansibleiscool`, `ssl_check_hostname=0`, `output_mode=json`.
- Saved search **`DCC CVE Alert`** already exists, enabled, cron `*/1 * * * *`, alert
  action `ansible_core` (webhook, `environment=DCC`). M1-E force-fire:
  `POST /servicesNS/-/-/saved/searches/DCC%20CVE%20Alert/dispatch`.

### A.6 M1-B rulebook commit (verified live 2026-09-29)
- Repo `gitea/defend-contain-comply`. Target path `extensions/eda/rulebooks/splunk-cve-alert.yml`
  does **not** exist yet (Gitea contents API → **404**, confirmed). Gitea reachable from
  `central` at `http://gitea:3000` (root → **200**).
- **Source content lives in Gitea, not the local checkout** — the workspace `lab/` dir is
  empty; the solution is committed in the repo at `lab/extensions/eda/splunk-cve-alert.yml`
  (decoy `…-exercise.yml`). So M1-B fetches the source from Gitea (raw or contents API,
  base64-decode) and commits it to the discoverable path, rather than reading a local file.
- Commit via `POST /api/v1/repos/gitea/defend-contain-comply/contents/extensions/eda/rulebooks/splunk-cve-alert.yml`
  (base64 content, Gitea token/basic auth), then re-sync the EDA project (A.5) and poll
  `import_state=completed`. Guard: skip commit if the target path already returns 200.
- **Rulebook rule contract (drives M1-E):** condition
  `event.payload.search_name is search("CVE Alert")`; action `run_workflow_template`
  name `Vulnerability Containment`, org `Default`, `job_args.limit = event.payload.results.host`,
  `extra_vars.affected_host = event.payload.results.host`. Source is `ansible.eda.pg_listener`
  with `token: EDA_WEBHOOK_TOKEN` (fed by the AAP Token Event Stream).
- **M1-E synthetic payloads already in Gitea:** `lab/templates/splunk-alert-payload-rhel02.json`
  (and `…-payload.json`) — post one straight at the event-stream receptor URL (token auth)
  with `results.host=rhel02` so the rule launches containment on rhel02.
