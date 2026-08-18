# Repository Agent Instructions

## Source of truth and documentation ownership

The scripts are authoritative. Before changing a subsystem, read its entry
point, sourced files, installed artifacts and relevant tests.

Keep documentation non-duplicative:

- `Readme.md`: user-facing purpose, installation and operation;
- `docs/architecture.md`: component ownership and persistent artifacts;
- `docs/boot-flow.md`: installation, boot and maintenance sequences;
- `docs/invariants.md`: properties that changes must preserve;
- `docs/testing.md`: validation procedure and external-tool inventory.

Update only the owning document and link to it elsewhere when necessary.

## Reasoning policy

Use the default reasoning effort for straightforward tasks.

For tasks involving:
- architectural decisions
- changes spanning multiple files
- non-trivial debugging
- security-sensitive changes
- ambiguous requirements

enter Plan mode before making changes.

## Model escalation

Use the primary agent for straightforward tasks.

Delegate to a subagent for tasks that require substantial reasoning, including:

- architectural decisions
- non-trivial debugging
- security-sensitive analysis
- changes spanning multiple subsystems
- ambiguous requirements
- investigation requiring comparison of several possible solutions

For straightforward implementation, exploration, formatting, and mechanical
changes, do not spawn a subagent.

When a task requires substantial reasoning, delegate that portion to the
`deep_reasoner` agent before implementing it.

## Scope and safety

`setup.sh` runs as root against a fresh Ubuntu or Kali installation. Ubuntu is
converted from the same live session after Ubiquity, with the target normally
mounted at `/target`; Kali may start with its configured filesystems unmounted.
The target ESP is `/target/boot/efi`, an optional separate boot is
`/target/boot`, and `/cdrom` is the Ubuntu rescue source.

The default devices are an optional rescue `/dev/sda1`, ESP `/dev/sda2` and
unencrypted Btrfs root `/dev/sda3`. Configuration may override them. Root
conversion, rescue creation and firmware enrollment are destructive. Never run
them on the development host or infer a target from ambiguous input.

Priorities are: bootability, data integrity, encryption/recovery, Secure Boot,
TPM sealing, rollback, maintainability, then user experience.

## Repository boundaries

- `setup.sh`: live/chroot orchestration and configuration wizard;
- `lib/`: functions genuinely shared by repository-bound scripts;
- `btrfs-root/`: Btrfs layout, separate-boot migration and LUKS conversion;
- `rescue/`: optional persistent live rescue partition;
- `secure-boot/`: keys, enrollment, rEFInd and fwupd;
- `btrfs-snapshots-mng/`: Snapper and early-boot snapshot selection;
- `uki/`: kernel-install, dracut, ukify and rEFInd menu integration;
- `tpm/`: TPM installation and enrollment commands;
- `tests/`: non-destructive shell tests.

Domain logic stays in its subsystem. Add a helper to `lib/` only when multiple
scripts actually share it. Installed `generate-uki`, `tpm-enroll`, `tpm-reseal`
and `tpm-status` must remain standalone after the repository is removed.

## Bash and framework rules

- Use Bash explicitly, quote expansions, arrays for argv, `local` variables and
  `set -euo pipefail` where compatible.
- Avoid `eval`, parsing `ls`, unnecessary subshells and unhandled expected
  failures.
- Namespace functions by owner, for example `common.require_root` and
  `btrfs-subvol-setup.validate_configuration`.
- Keep every `cat` heredoc visibly indented. Use `<<-EOF` with leading tabs when
  generated output must start in column zero.
- Never log passphrases, PINs, recovery keys or private material.

Repository logging lives only in `lib/log.sh` and uses `log.*`. Standalone
installed commands embed compatible local primitives. Preserve icons/colors,
unstyled summary values and paired rotating `log.section` BEGIN/END banners.
`log.die` must preserve the failing status; pass captured stderr only when it is
known not to contain secrets.

Primary setup scripts end with a truthful summary followed immediately by a
`Post-summary validation`. Validation must be read-only with respect to
firmware, LUKS tokens, TPM state and snapshots.

## Change-sensitive contracts

The complete contract is in `docs/invariants.md`; do not duplicate it here.
Before changing storage, Secure Boot, UKI, TPM or snapshot behavior, trace the
relevant invariant to every producer, installed artifact and consumer. Treat
device validation, recoverable LUKS access and verified boot artifacts as hard
preconditions rather than cleanup work.

## Configuration

`setup.conf` is sourced shell code, mode 0600, ignored by Git and potentially
secret-bearing. `setup.conf.example` is reference data only; wizard defaults
remain built into `setup.sh`.

The wizard discovers mounted Ubuntu targets or selects Kali target partitions,
groups prompts, uses hidden secret input and yes/no toggles, validates its
generated file, displays a non-secret summary and requires confirmation before
installation. It does not prompt for `mp`, `keyslot_size`, `btrfs_options` or
experimental sbctl append behavior.

Only these closed selections are supported currently:

- `suite`: `resolute`, `noble`, `kali`;
- `suite_type`: `ubuntu`, `kali`; selecting suite `kali` forces type `kali`;
- `secure_boot_enrollment`: `sbctl`, `mok`;
- `secure_boot_mode`: detected `setup`, `enabled`, `disabled`, `unknown`;
- `EXPERIMENTAL_SBCTL_APPEND`: `true`, `false`.

`mok_pin` is required only for MOK. Kali forces `install_rescue=no` during the
main installation. Otherwise, `install_rescue=no` permits an empty
`rescue_dev`; the standalone rescue action still requires one. `sb_key_dir` is
currently unused. Preserve the repository-root `refind_themes.zip` dependency.

## Validation and completion

For every modified shell file, including extensionless executables, run
`bash -n`, ShellCheck and `shfmt -d`, then relevant unit tests. Do not rely on
`tests/validate.sh` alone; its coverage is incomplete. Inspect the final diff
for secrets, private keys and boot/security regressions.

Never describe static or mocked checks as proof of boot, reencryption, firmware,
MOK or TPM behavior. Use the evidence labels defined in `docs/testing.md`.

The repository is GPL-3.0-only. Preserve `LICENSE` and follow `SECURITY.md` for
private vulnerability reports.
