# Defend, Contain, Comply — Lab Summary

## Goal

A hands-on Ansible Automation Platform (AAP) workshop that walks a learner through a
complete **vulnerability lifecycle** on RHEL, framed as an incident at fictional
"Parasol Finance." The learner plays a platform engineer responding to a critical CVE
(**CVE-2024-38476**, a CVSS 9.8 SSRF in Apache `mod_rewrite`) for which no patch exists yet.

The workshop proves three capabilities end-to-end:

- **DEFEND** — Detect the CVE via Splunk, contain it manually, then automate the same
  containment with Event-Driven Ansible (EDA) so a second server is contained in seconds.
- **CONTAIN** — Once an errata (RHSA-2024:5138) is published, apply a policy-gated patch
  workflow enforced by Open Policy Agent (OPA) with a human approval gate and auto-generated
  compliance evidence.
- **COMPLY** — Audit the system against OPA compliance policies, apply CIS hardening,
  produce before/after evidence, then build, scan, and push a hardened container image.

**Duration:** ~2h15m (Module 1 ~40 min, Module 2 ~40 min, Module 3 ~45 min, wrap-up ~10 min).

## Environment

| Host | Role |
|------|------|
| `aap-controller` | AAP Controller 2.5 — workflow orchestration (Web UI) |
| `eda-controller` | EDA Controller — rulebook activations (Web UI) |
| `rhel01` | RHEL 9 target running vulnerable `httpd` (Terminal/SSH) |
| `rhel02` | Second RHEL 9 target used for the automated-response demo |
| `localhost:5000` | Podman container registry (used in Module 3) |

Also used: Splunk (detection), Gitea (source repo for rulebooks/playbooks/policies),
OPA (policy engine on `central:8181` / `192.168.1.11`), Compliance Portal (report viewer).

**Credentials:** AAP `admin` / `ansible123!`; SSH `rhel` / `ansible123!`;
Splunk `admin` / `ansible123!`; Gitea `gitea` / `ansible123!`.

---

## Every step the learner completes

### Module 1 — DEFEND (Detect and Contain)

**Part 1: Manual response on rhel01**

*Exercise 1 — Investigate the CVE in Splunk*
1. Open the **Portal - rhel01** tab; confirm the portal is up and publicly accessible.
2. Open the **Splunk** tab and log in (`admin` / `ansible123!`).
3. Go to **Search & Reporting**.
4. Run the search for CVE / httpd / vulnerability events; confirm events on `rhel01`.
5. Examine event details (host, CVE, CVSS 9.8, package `httpd-2.4.57-5.el9`, advisory).
6. Run the aggregated `stats count by host, source` search that powers the saved alert.
7. Go to **Settings → Searches, reports, and alerts** and find the **DCC CVE Alert** saved search.

*Exercise 2 — Confirm the vulnerability from AAP*
8. Open the **AAP Controller** tab and log in.
9. Go to **Automation Execution → Templates**; find **DEFEND - Scan System**.
10. Launch it with **Limit** = `rhel01`.
11. Watch output confirm the CVE and vulnerable `httpd` package.

*Exercise 3 — Manually run the containment workflow*
12. Open the **Terminal**, `ssh rhel01`, password `ansible123!`.
13. Baseline: run `firewall-cmd --get-active-zones` (both interfaces in `public`).
14. Baseline: run `firewall-cmd --zone=public --list-all` (http/https/ssh open).
15. Baseline: check `systemctl status httpd`.
16. Baseline: `curl` localhost, expect HTTP 200.
17. Confirm the portal loads in the **Portal - rhel01** tab.
18. In AAP, find the **Vulnerability Containment** workflow template.
19. Launch it with **Limit** = `rhel01`.
20. Watch the three chained steps run: Scan System → Contain Service → Harden Posture.
21. Wait for the workflow to complete.
22. Verify: refresh **Portal - rhel01** — it should no longer be reachable.
23. Verify `eth0` moved to `internal-only` zone; `eth1` stays in `public`.
24. Verify http/https removed from the `public` zone.
25. Inspect the `internal-only` zone (eth0, ssh only).
26. Confirm httpd is still running.
27. Confirm the portal still answers internally via `curl http://192.168.1.13` (HTTP 200).
28. Verify httpd hardening (`ServerTokens Prod`, `ServerSignature Off`).
29. Verify security headers are served.
30. Verify SELinux booleans are all `off`.
31. Confirm AIDE file-integrity cron job exists.
32. Read the containment audit log `/var/log/containment-actions.log`.

**Part 2: Automated response on rhel02**

*Exercise 4 — Write the EDA rulebook*
33. Open **Gitea** and log in (`gitea` / `ansible123!`).
34. Browse to the `defend-contain-comply` repository.
35. Create `/extensions/eda/rulebooks/splunk-cve-alert.yml` with the provided rulebook
    (matches `search_name is search("CVE Alert")` → runs the Vulnerability Containment workflow,
    passing the affected host as `job_args.limit`).
36. Commit, then sync the EDA project in AAP (**Automation Decisions → Projects → Sync**).

*Exercise 5 — Connect Splunk to EDA*
37. In **Automation Decisions → Infrastructure → Credentials**, create a **Token Event Stream**
    credential `Splunk EDA Token` (token `ansibleiscool`, header key `Authorization`).
38. In **Event Streams**, create event stream `Splunk EDA` using that credential.
39. Copy the Event Stream URL and token.
40. In **Splunk → Apps → Event Driven Ansible Add-on → Configuration**, add a webhook
    integration `Splunk2EDA` (environment `DCC`, endpoint using `192.168.1.10`,
    API key `ansibleiscool`, SSL hostname check off).
41. In AAP **Automation Decisions → Rulebook Activations**, create
    `DCC CVE Alert Responder` (project, `splunk-cve-alert.yml`, default DE,
    `DCC Controller Token`, event stream `Splunk EDA`).
42. Wait for activation status **Running**.

*Exercise 6 — Deploy the app to rhel02*
43. In AAP, launch **DEFEND - Deploy Application** with **Limit** = `rhel02`.
44. Wait for completion (deploys vulnerable httpd + portal + errata repo).
45. Confirm the **Portal - rhel02** tab is up.

*Exercise 7 — Trigger EDA and watch automated containment*
46. Launch **DEFEND - Scan System** with **Limit** = `rhel02` (reports the finding to Splunk).
47. In Splunk, confirm the **DCC CVE Alert** saved search fires (or run it manually).
48. In AAP **Automation Decisions → Event Streams / Rule Audit**, confirm the event was
    received and matched; inspect the launched action.
49. In **Automation Execution → Jobs**, watch **Vulnerability Containment** launch
    automatically, limited to `rhel02`.
50. Refresh **Portal - rhel02** — it should now be blocked.
51. Compare Portal rhel01 (manual) vs rhel02 (automatic).
52. Verify containment on rhel02: `ssh rhel02 sudo firewall-cmd --get-active-zones`.
53. Launch **DEFEND - Verify Security Posture** to compare posture across both hosts.

### Module 2 — CONTAIN (Patch and Enforce)

*Exercise 1 — Examine the patch policy*
54. In **Gitea**, open `lab/policies/patch-policy.yml`; note the four automatable gates
    (maintenance window, backup, disk, service health) plus the AAP approval gate.
55. In Terminal, simulate a recent backup: `ssh rhel01 sudo touch /var/log/last-backup-timestamp`.
56. Verify OPA is running and the patch policy is loaded (curl `central:8181`).

*Exercise 2 — Write the pre-patch policy check playbook*
57. In Gitea, read the Rego policy in `lab/policies/patch-policy.yml` (5 checks).
58. In Gitea, open `lab/playbooks/contain/pre-patch-check.yml` and uncomment the
    **Query OPA patch policy** task.
59. Commit, sync the **DCC Workshop** project in AAP, and test-launch
    **CONTAIN - Pre-Patch Check**.

*Exercise 3 — Build the patching workflow*
60. In AAP **Resources → Templates**, add a new **workflow template** `Policy-Gated Patching`
    (org Default, inventory DCC Workshop).
61. Open the **Visualizer**.
62. Node 1 — add job template **CONTAIN - Pre-Patch Check**.
63. Node 2 — add an **Approval** node `Approve Patch Application` (timeout 900s, run on success).
64. Node 3 — on **On Approve**, add **CONTAIN - Patch System**.
65. Node 4 — on success, add **CONTAIN - Post-Patch Verify**.
66. Node 5 — on success, add **CONTAIN - Report Compliance**.
67. Review the five-node linear chain and **Save**.

*Exercise 4 — Policy-as-code execution gate*
68. In Gitea, read `lab/setup/files/opa-policies/dcc-execution-policy.rego`
    (authorized user = `security_engineer`).
69. In AAP **Settings → Automation Execution → Policy**, set OPA server hostname `192.168.1.11`.
70. In **Access Management → Organizations → Default**, set Policy Enforcement path
    `aap/gateway/decision`.
71. As `admin`, attempt to launch **Policy-Gated Patching**; observe the platform block it
    (authorization error).
72. In **Authentication Methods → Users**, set the `security_engineer` password to `ansible123!`.
73. Log out of AAP.
74. Log back in as `security_engineer`.

*Exercise 5 — Execute the patching workflow*
75. As `security_engineer`, run the **Policy-Gated Patching** workflow.
76. Watch **CONTAIN - Pre-Patch Check** gather facts and evaluate OPA gates
    (simulate the rhel02 backup marker if that gate fails; adjust maintenance window via
    **CONTAIN - Update Maintenance Window** if needed).
77. When the workflow pauses at the approval node, open the **Bell** notification and
    **Approve** the patch.
78. Watch Patch System → Post-Patch Verify → Report Compliance complete.
79. Verify the patch: `ssh rhel01 rpm -q httpd` (expect `httpd-2.4.62-1.el9`+).
80. Confirm the CVE is no longer pending (`yum updateinfo list cves`).
81. Confirm httpd still running with the patched version.

*Exercise 6 — Review the compliance report*
82. Open the **Compliance Portal** tab and view the generated HTML report.
83. Check the report on rhel01: `ssh rhel01 ls -la /tmp/compliance-reports/`.
84. Grep the report for advisory / remediation evidence and package versions.
85. In AAP **Jobs**, open the workflow job and inspect the `set_stats` artifacts
    (`pre_patch_policy_passed`, `patch_applied`, `cve_resolved`, `selinux_enforcing`).

*Exercise 7 — Test policy violation (optional)*
86. Confirm the backup marker exists on rhel01.
87. Remove it (`rm -f /var/log/last-backup-timestamp`).
88. Launch **CONTAIN - Pre-Patch Check** alone; watch OPA return `allow_patch: false` and fail.
89. Restore the marker (`touch`), then re-run the check to confirm it passes.

### Module 3 — COMPLY (Audit, Harden, Deliver)

*Exercise 1 — Review OPA compliance policies*
90. In Gitea, read `lab/setup/files/opa-policies/dcc-compliance.rego`.
91. Identify the 13 controls and their categories (SELinux, firewall, SSH, kernel,
    file permissions, services, vulnerability).
92. Verify OPA has `policies/dcc-compliance.rego` loaded (curl).
93. Test a single control via the OPA REST API, toggling SELinux Enforcing/Permissive.

*Exercise 2 — Run the pre-hardening audit*
94. In AAP, launch **COMPLY - Compliance Audit** with `audit_phase: pre`.
95. Wait for completion.
96. In the **Compliance Portal**, open the pre-hardening report and note failed controls.

*Exercise 3 — Apply CIS hardening*
97. In AAP, launch **COMPLY - CIS Harden**.
98. Verify SSH hardening via `sshd -T` (permitrootlogin no, x11forwarding no, maxauthtries 4,
    clientaliveinterval 300).
99. Verify file permissions on passwd/shadow/group/gshadow.
100. Verify kernel params (accept_redirects 0, send_redirects 0, randomize_va_space 2).
101. Confirm unnecessary services (rpcbind, avahi) are disabled.

*Exercise 4 — Re-audit and generate report*
102. Launch **COMPLY - Compliance Audit** with `audit_phase: post`.
103. In the Compliance Portal, compare pre vs post reports (all controls now pass).
104. Launch **COMPLY - Compliance Report** to generate the full HTML report.
105. View the before/after evidence in the portal.

*Exercise 5 — Build the hardened container image*
106. In Gitea, review `lab/templates/Containerfile.j2` (UBI9-minimal base, httpd+mod_ssl,
     non-root apache user, advisory labels).
107. Launch **COMPLY - Build Container**.
108. Verify the image: `ssh rhel01 sudo podman images`.
109. Inspect image labels for advisory/remediation metadata.
110. Check the image size (minimal base).

*Exercise 6 — Scan the image and push to registry*
111. Launch **COMPLY - Scan Image** (uses the Trusted Pipeline EE with `oscap-podman`).
112. Confirm the CVE is absent from the scan results.
113. Launch **COMPLY - Push to Registry**.
114. Verify the image via the registry catalog API (`localhost:5000/v2/_catalog`).
115. List the image tags.

*Exercise 7 — Run the full compliance workflow*
116. In AAP, open the **Compliance and Hardening** workflow template.
117. In the Visualizer, review the 7-node chain
     (Audit Pre → CIS Harden → Audit Post → Report → Build → Scan → Push).
118. Launch the workflow.
119. Watch each node complete.
120. Review the workflow `set_stats` artifacts (`pre_audit_pass_count`,
     `post_audit_pass_count`, `hardening_controls_applied`, `report_path`).
121. Verify end-to-end from the terminal (report, container image, registry catalog).

### Conclusion
122. Read the recap of the full Defend → Contain → Comply flow and business outcomes.

---

## Outcome

By the end, the learner has: contained a zero-patch CVE both manually and automatically
(mean-time-to-contain reduced from ~45 min to seconds), applied a patch only after passing
OPA state gates + separation-of-duties enforcement + human approval, and produced auditable
before/after compliance evidence plus a scanned, hardened container in a trusted registry.
