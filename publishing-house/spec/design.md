# Defend, Contain, Comply: Automated Vulnerability Response with Ansible

## Overview

This hands-on lab walks participants through an end-to-end vulnerability response lifecycle orchestrated by Red Hat Ansible Automation Platform. The lab demonstrates how security teams can move from manual, reactive CVE remediation to automated, policy-gated workflows that detect threats, contain compromised systems, enforce patching policies, and deliver auditable compliance evidence.

Participants will investigate a CVE alert in Splunk, manually execute containment playbooks (firewall isolation, service hardening, SELinux enforcement), then build an Event-Driven Ansible rulebook that automates the same response. They will construct an OPA-gated remediation workflow in AAP with approval gates and policy-as-code execution checks, then run a full compliance pipeline that audits systems against CIS benchmarks, hardens them, generates HTML compliance reports, and builds hardened container images scanned with OpenSCAP.

## Target Audience

- **Role:** Security engineers, platform engineers, system administrators responsible for vulnerability management and compliance
- **Experience level:** Intermediate
- **What they already know:** Basic Ansible playbook authoring, RHEL system administration, CVE and security advisory concepts
- **What they don't know:** How to integrate Event-Driven Ansible with SIEM tools for automated incident response, how to use OPA policies as execution gates in AAP workflows, and how to build auditable compliance pipelines that produce hardened container images

## Prerequisites

- Basic experience writing and running Ansible playbooks
- Familiarity with RHEL system administration (SSH, systemd, package management)
- Understanding of CVE and security advisory concepts
- Can the lab validate these automatically? No -- prerequisites are knowledge-based skills, not automatable checks

## Learning Objectives

1. Implement automated CVE detection and containment by integrating Splunk alerts with Event-Driven Ansible rulebooks
2. Build policy-gated remediation workflows in AAP using OPA policies as execution gates and approval nodes
3. Deploy end-to-end compliance pipelines that audit systems against CIS benchmarks, apply hardening, and generate HTML compliance reports
4. Create hardened container images from UBI9-minimal with OpenSCAP scanning and push them to a local registry
5. Automate multi-step vulnerability response workflows that combine firewall isolation, service hardening, SELinux enforcement, and AIDE integrity monitoring

## Content Type

Lab (hands-on)

## Products & Technologies

- Red Hat Ansible Automation Platform 2.5 (Controller + EDA Controller)
- Event-Driven Ansible (EDA)
- Red Hat Enterprise Linux 9.4/9.5
- Red Hat UBI9-minimal (container base image)
- Open Policy Agent (OPA)
- Splunk Enterprise Security
- Podman
- oscap-podman / OpenSCAP
- Gitea
- Apache HTTP Server (httpd) with mod_ssl
- AIDE (Advanced Intrusion Detection Environment)
- CIS Benchmarks
- SELinux, firewalld

## Module Map

| Module | Title | Duration |
|--------|-------|----------|
| 1 | DEFEND: Detect and Contain | 40 min |
| 2 | CONTAIN: Policy-Gated Remediation | 40 min |
| 3 | COMPLY: Audit, Harden, Deliver | 45 min |
| -- | **Total hands-on** | **2 hours 5 min** |
| -- | Intro + Overview + Conclusion | ~25 min |
| -- | **Total lab** | **~2.5 hours** |

## Difficulty Level

Intermediate

## Environment

**Learner view:** When the lab starts, participants have SSH access to four pre-provisioned RHEL VMs. The control node runs AAP Controller and EDA Controller (pre-installed). Two application servers (rhel01, rhel02) host a vulnerable web application. A central services node runs Splunk Enterprise Security, an OPA server, a local errata repository, and a compliance reporting portal. A Gitea instance is available for version-controlling EDA rulebooks and automation content. AAP inventories, credentials, and project configurations are pre-populated.

**Automation needed:** Yes

- AAP Controller and EDA Controller installed and configured on the control node
- Splunk Enterprise Security deployed on the central node with pre-configured indexes and alerts
- OPA server running on the central node with baseline policy bundles
- Gitea instance with pre-seeded repositories for rulebooks and playbooks
- Vulnerable web application deployed on rhel01 and rhel02
- Local errata repository and compliance portal on the central node
- AAP inventories, credentials, and projects pre-configured

## Infrastructure Requirements

- **Cloud provider:** CNV
- **Cluster type:** N/A (VM-based lab, not OCP workloads)
- **OCP version:** N/A
- **Topology:** Per-student
- **Sizing:** 4 VMs per student: 1 control (8 vCPU, 64GB RAM, 80GB disk), 2 app servers (4 vCPU, 16GB RAM, 30GB disk each), 1 central services (4 vCPU, 8GB RAM, 30GB disk) + Gitea container (4GB memory)
- **Automation approach:** Ansible
- **AI/MaaS:** None
- **External services:** registry.access.redhat.com, github.com
- **AAP version:** 2.5
- **Non-GA products:** None (all products are GA)

## Assessment Strategy (Optional)

Each module contains 7 exercises with explicit verification steps. Participants confirm successful completion through observable outcomes: Splunk alert correlation, AAP job completion status, workflow node results, OPA policy evaluation outputs, compliance report generation, and container image scan results in the local registry.
