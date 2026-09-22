# Security policy

<p align="center">
  <img src="https://raw.githubusercontent.com/DaemonCores/.github/refs/heads/main/assets/banner.svg" alt="AstralEmu Banner" width="100%"/>
</p>

<p>
  <strong align="left">Simplify and Innovate for Everyone.</strong>
  <a href="https://github.com/DaemonCores/debian-bootc/wiki"><img align="right" src="https://img.shields.io/badge/Wiki-FFFFFF?style=for-the-badge&logoColor=white" alt="Documentation"/></a>
  <a href="https://github.com/orgs/DaemonCores/discussions"><img align="right" src="https://img.shields.io/badge/Community-000000?style=for-the-badge&logoColor=white" alt="Community"/></a>
  <a href="https://github.com/DaemonCores/debian-bootc"><img align="right" src="https://img.shields.io/badge/Base_debian_for_all_project-A81D33?style=for-the-badge&logo=debian&logoColor=white" alt="Debian Bootc"/></a>
  
  <em>Identify gaps and fill them, make improvements where possible, but above all, empower developers to offer more to users.</em>
</p>

---

## Private reporting

Use [GitHub private vulnerability reporting](https://github.com/DaemonCores/DaemonCores-VE/security/advisories/new) or email `guillou.gabriel@gmail.com`. Do not open a public issue for an undisclosed vulnerability.

Include the affected commit or image digest, package versions, impact, reproduction steps, and sanitized logs.

## Supported state

Security fixes target the current default branch and the newest artifacts produced from it. There is no versioned long-term-support channel; older images and installer media should be treated as unsupported.

## Important security boundaries

- DaemonCores-VE inherits the boot chain, installer, APT trust, and image-signing boundaries from `debian-bootc`.
- Project packages run with host privileges and can modify networking, firewall, storage, swap, cooling, power, or Proxmox state.
- `dc-config-zfs`, `pvect-ostree`, and installer paths handle persistent storage and require special review.
- `fanctl` and `powerctl` must fail safely on unsupported or implausible hardware inputs.
- The repacked `pve-manager` changes subscription-status behaviour; it does not grant a subscription or vendor support.
- Privileged CI jobs must not execute untrusted contribution code with release credentials.

Supply-chain bypasses, unsafe hardware writes, isolation failures, installer disk-selection errors, credential exposure, and unexpected privilege escalation introduced by project code are in scope.

---

<p>
  <strong align="left">Made with ⭐ by the DaemonCores community</strong>
  <a href="https://github.com/DaemonCores/debian-bootc/wiki"><img align="right" src="https://img.shields.io/badge/Wiki-FFFFFF?style=for-the-badge&logoColor=white" alt="Documentation"/></a>
  <a href="https://github.com/orgs/DaemonCores/discussions"><img align="right" src="https://img.shields.io/badge/Community-000000?style=for-the-badge&logoColor=white" alt="Community"/></a>
  <a href="https://github.com/DaemonCores/debian-bootc"><img align="right" src="https://img.shields.io/badge/Base_debian_for_all_project-A81D33?style=for-the-badge&logo=debian&logoColor=white" alt="Debian Bootc"/></a>
</p>
