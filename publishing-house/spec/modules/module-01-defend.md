# Module 01: DEFEND -- Detect and Contain

### Brief Overview

This module introduces the vulnerability detection and containment phase of the lab. Participants start by investigating a CVE alert in Splunk Enterprise Security, confirming the vulnerability through an AAP-driven scan, and then manually executing a containment workflow that isolates the affected system with firewall rules, hardens the httpd service, enforces SELinux policies, and deploys AIDE for file integrity monitoring. In the second half, participants shift to automation: they write an Event-Driven Ansible rulebook in Gitea, configure the Splunk-to-EDA integration, deploy a vulnerable application, and observe the entire containment sequence execute automatically in response to a live Splunk alert.

### Audience and Time

- **Target personas:** Security engineers, platform engineers, system administrators managing vulnerability response
- **Prerequisites for this module:** Familiarity with Ansible playbooks, SSH access to RHEL systems, basic understanding of CVE advisories
- **Estimated duration:** 40 minutes

### Learning Objectives

- Implement manual CVE containment by executing firewall isolation, httpd hardening, SELinux enforcement, and AIDE integrity monitoring playbooks
- Integrate Splunk Enterprise Security alerts with Event-Driven Ansible to trigger automated containment workflows
- Build and deploy an EDA rulebook in Gitea that responds to security events without human intervention

### Lab Structure

| Section | Title | Duration |
|---------|-------|----------|
| 1 | Investigate CVE alert in Splunk | 5 min |
| 2 | Confirm vulnerability with AAP scan | 5 min |
| 3 | Manually run containment workflow: firewall isolation | 5 min |
| 4 | Manually run containment workflow: httpd hardening and SELinux | 5 min |
| 5 | Manually run containment workflow: AIDE deployment | 5 min |
| 6 | Write EDA rulebook in Gitea and configure Splunk integration | 7 min |
| 7 | Deploy vulnerable app and observe automated containment | 8 min |

### Detailed Steps

1. Navigate to the Splunk Enterprise Security dashboard on the central node. Review the CVE alert details, noting the affected host, severity, and CVE identifier.
2. In AAP Controller, launch the vulnerability scan job template against the affected host. Verify the scan output confirms the CVE.
3. Run the firewall isolation playbook from AAP. SSH to the affected host and verify that firewalld rules now block inbound traffic except from the control node.
4. Run the httpd hardening playbook. Verify that mod_ssl is configured and the service has restarted with updated settings.
5. Run the SELinux enforcement playbook. Confirm SELinux is set to enforcing mode and appropriate booleans are configured.
6. Run the AIDE initialization playbook. Verify the AIDE database is created and a baseline integrity check completes.
7. In Gitea, create a new EDA rulebook that listens for Splunk webhook events and triggers the containment workflow. Commit and push the rulebook.
8. In EDA Controller, configure the Splunk event source and activate the rulebook.
9. Deploy the vulnerable application on rhel01 using the provided playbook.
10. Observe in the EDA Controller that the Splunk alert triggers the rulebook, which launches the full containment workflow automatically.
11. Verify automated containment by checking firewall rules, httpd configuration, SELinux status, and AIDE baseline on the affected host.

### Key Takeaways

- Manual CVE containment is effective but time-consuming and error-prone at scale
- Event-Driven Ansible transforms reactive incident response into automated, repeatable containment
- Splunk-to-EDA integration provides a closed-loop detection-to-containment pipeline
- Each containment step (firewall, service hardening, SELinux, AIDE) addresses a different attack surface

### Infrastructure Notes

- Splunk Enterprise Security is pre-deployed on the central node with indexes and alerts pre-configured
- EDA Controller runs alongside AAP Controller on the control node
- Gitea is available as a container on the central node for version-controlling rulebooks
- The vulnerable application deployment uses a pre-built playbook that introduces a known CVE on rhel01
