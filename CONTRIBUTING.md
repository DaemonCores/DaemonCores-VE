# Contributing to DaemonCores-VE

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

Contributions are welcome for Proxmox packaging, bootc integration, host services, runtime tests, and documentation.

## Bug reports

Include the commit or image digest, Proxmox package versions, deployment method, hardware or VM configuration, reproduction steps, and relevant service logs. For hardware-control issues, include detected backends and sanitized configuration without executing additional write operations solely for diagnosis.

Use the repository issue forms for public bugs and feature proposals. Follow [SECURITY.md](SECURITY.md) for private reports.

## Development areas

| Area | Main paths |
| --- | --- |
| Image layer | `Containerfile`, `src/` |
| Package and host tools | `workflows/bootc-debs-builder/` |
| Runtime validation | `workflows/image-tests/tests.yml` |
| Shared pipeline caller | `.github/workflows/pipeline.yml` |
| Documentation | `README.md`, `docs/` |

## Change requirements

- Keep upstream repacks minimal and versioned with the project suffix.
- Add a package or runtime test for every patch marker and service behaviour.
- Preserve safe no-op behaviour on unsupported fan, power, storage, and IPMI backends.
- Do not weaken the disk-selection prompt, package-key verification, or image-signing path.
- Test changes in a disposable virtual machine before physical deployment.
- State which hardware-dependent paths were not tested.
- Update documentation in the same pull request.

Cross-repository changes to `debian-bootc` or `DaemonCores-CI` must describe the compatible revisions required by every repository.

---

<p>
  <strong align="left">Made with ⭐ by the DaemonCores community</strong>
  <a href="https://github.com/DaemonCores/debian-bootc/wiki"><img align="right" src="https://img.shields.io/badge/Wiki-FFFFFF?style=for-the-badge&logoColor=white" alt="Documentation"/></a>
  <a href="https://github.com/orgs/DaemonCores/discussions"><img align="right" src="https://img.shields.io/badge/Community-000000?style=for-the-badge&logoColor=white" alt="Community"/></a>
  <a href="https://github.com/DaemonCores/debian-bootc"><img align="right" src="https://img.shields.io/badge/Base_debian_for_all_project-A81D33?style=for-the-badge&logo=debian&logoColor=white" alt="Debian Bootc"/></a>
</p>
