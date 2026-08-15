# Security Policy

## Supported versions

Security fixes are developed for the current repository state. Older snapshots,
forks and locally modified installations are not maintained by this project.

| Version | Security support |
| --- | --- |
| Current default branch | Supported |
| Older revisions and forks | Not supported |

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose secrets,
bypass Secure Boot, weaken LUKS or TPM policy, corrupt storage, or enable code
execution during boot.

Report it privately through the repository's
[GitHub security advisory form](https://github.com/michelemadonna/ubuntu-btrfs-on-root/security/advisories/new).

Include, when available:

- the affected script, command and revision;
- the expected security property and observed behavior;
- the Ubuntu release, architecture, firmware mode and Secure Boot state;
- relevant LUKS, TPM2, UKI, dracut, rEFInd and kernel versions;
- minimal reproduction steps using a disposable system or VM;
- logs with passphrases, PINs, recovery keys, private keys, TPM material,
  machine identifiers and device-specific sensitive data removed;
- whether exploitation requires root access, physical access or a reboot.

Please allow time to reproduce and assess the report before publishing details.
No fixed response or remediation deadline is guaranteed.

## Security-sensitive scope

Reports are especially relevant when they affect:

- LUKS formatting, reencryption, keyslots or recovery access;
- Secure Boot signing, firmware keys, shim or MOK trust;
- UKI construction, validation, PCR signatures or kernel command lines;
- TPM enrollment, resealing, PCR policy or automatic unlock;
- Btrfs subvolume isolation, snapshot selection or read-only snapshot boot;
- rescue partition sizing, formatting or target-device validation;
- command injection, unsafe configuration sourcing or secret disclosure.

## Safe reproduction

Never reproduce a storage, encryption, firmware or TPM issue on a production
machine. Use a disposable UEFI VM or dedicated test system with recoverable
data. Do not attach real credentials or private signing keys to a report.

If a report concerns a machine that may already be compromised, stop using its
automatic unlock path, preserve recovery access, and rotate affected secrets
and signing material through an independently trusted environment.
