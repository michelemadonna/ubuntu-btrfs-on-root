# Repository Agent Instructions

## Sources and document ownership

Scripts are authoritative. Before changing a subsystem, read its entry point,
sources, installed artifacts, tests and invariants.

- `Readme.md`: user purpose, installation and operation;
- `docs/architecture.md`: component ownership and persistent artifacts;
- `docs/boot-flow.md`: installation, boot and maintenance order;
- `docs/invariants.md`: properties every change must preserve;
- `docs/testing.md`: validation, evidence labels and external tools.

Update only the owning document; link instead of duplicating content.

## Working method

Use default reasoning for straightforward work. Before architectural,
multi-file, security-sensitive, ambiguous or non-trivial debugging changes,
enter Plan mode and delegate substantial reasoning to `deep_reasoner`. Keep
mechanical work in the primary agent.

## Scope and safety

`setup.sh` runs as root on fresh Ubuntu/Kali. `migration` converts it;
`new` delegates whole-disk provisioning to `new-install/`. Never mutate storage,
rescue, firmware, LUKS, TPM or Secure Boot on the development host, or infer a
destructive target from ambiguous input.

Ubuntu migration normally uses root `/target`, ESP `/target/boot/efi`, optional
boot `/target/boot` and rescue source `/cdrom`; Kali may begin unmounted.
Defaults—configurable—are rescue `/dev/sda1`, ESP `/dev/sda2` and unencrypted
Btrfs root `/dev/sda3`.

Priorities are bootability, data integrity, encryption/recovery, Secure Boot,
TPM sealing, rollback, maintainability, then user experience.

## Repository boundaries

- `setup.sh`: wizard and live/chroot orchestration;
- `lib/`: genuinely cross-cutting repository helpers;
- `new-install/`: validated whole-disk GPT, fresh LUKS/Btrfs and bootstrap;
- `btrfs-root/`: migration layout, separate boot and LUKS conversion;
- `rescue/`: persistent live rescue partition;
- `secure-boot/`: keys, enrollment, rEFInd and fwupd;
- `btrfs-snapshots-mng/`: Snapper and early-boot snapshot selection;
- `uki/`: kernel-install, dracut, ukify and rEFInd menu integration;
- `tpm/`: TPM installation and explicit enrollment commands;
- `tests/`: non-destructive shell tests.

Keep domain logic in its subsystem. Add to `lib/` only for real multi-script
consumers. Installed `generate-uki`, `tpm-enroll`, `tpm-reseal` and `tpm-status`
remain standalone after repository removal.

## Bash, logging and generated files

- Use Bash explicitly, quote expansions, arrays for argv, `local` variables and
  `set -euo pipefail` where compatible.
- Avoid `eval`, parsing `ls`, unnecessary subshells and unhandled expected
  failures.
- Namespace functions by owner, for example `common.require_root` and
  `btrfs-subvol-setup.validate_configuration`.
- Keep every `cat` heredoc visibly indented; use `<<-EOF` with leading tabs when
  output must begin in column zero.
- Never log passphrases, PINs, recovery keys or private material.

Repository logging lives in `lib/log.sh` as `log.*`; standalone commands embed
compatible primitives. Preserve icons/colors, unstyled summary values, paired
rotating `log.section` BEGIN/END banners and `log.die` failure status. Include
captured stderr only when known secret-free.

Primary setup scripts end with a truthful summary immediately followed by
read-only `Post-summary validation`; it never changes firmware, LUKS tokens,
TPM state or snapshots.

## Change-sensitive contracts

`docs/invariants.md` is the complete behavioral contract. Before changing
storage, Secure Boot, UKI, TPM or snapshots, trace the invariant through every
producer, installed artifact and consumer. Device validation, recoverable LUKS
access and verified boot artifacts are preconditions, not cleanup.

## Configuration

`setup.conf` is sourced shell code, mode 0600, Git-ignored and potentially
secret-bearing. `setup.conf.example` is reference data only; wizard defaults
remain built into `setup.sh`.

The wizard discovers migration mounts or selects an unused disk, groups prompts,
hides typed secrets, validates configuration, shows a non-secret summary and
requires confirmation. It does not prompt for `mp`,
`keyslot_size`, `btrfs_options` or experimental sbctl append behavior.

Supported closed values, literal-toggle behavior and mode-specific rescue,
Windows, suite and Secure Boot rules are owned by `docs/invariants.md`.
Preserve the repository-root `refind_themes.zip` dependency.

## Validation and completion

Follow `docs/testing.md`; do not rely on `tests/validate.sh`. Validate changed
shell files, run relevant unit tests and `git diff --check`, then inspect the
diff for secrets, private keys and boot/security regressions.

Never claim static or mocked checks prove boot, reencryption, firmware, MOK or
TPM behavior. Report evidence using the labels in `docs/testing.md`.

The repository is GPL-3.0-only. Preserve `LICENSE` and follow `SECURITY.md` for
private vulnerability reports.
