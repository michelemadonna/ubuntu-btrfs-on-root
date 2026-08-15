# Repository Agent Instructions

## Purpose and source of truth

This repository converts an Ubuntu installation created by Ubiquity into a
Btrfs, LUKS2, Secure Boot, UKI, TPM2 and Snapper system. It also copies the
Ubuntu live environment to a dedicated rescue partition.

The executable scripts are the authoritative description of current behavior.
Documentation must describe what those scripts do now, not a desired future
architecture. Before changing code, inspect its callers, generated files and
boot/security consequences.

## Required installation context

The normal entry point is `setup.sh`, executed as root from the same Ubuntu live
session in which Ubiquity has just completed the installation. Do not reboot
into the installed system first.

Ubiquity must use manual partitioning with this default layout:

- `/dev/sda1`: oversized GPT partition reserved for rescue; setup shrinks its
  leading FAT portion to at least 7168 MiB and converts the remaining range into
  a separate ext4 partition labelled `writable`;
- `/dev/sda2`: FAT32 EFI System Partition mounted by Ubiquity at `/boot/efi`;
- `/dev/sda3`: unencrypted Btrfs filesystem mounted by Ubiquity at `/`.

The setup scripts assume the installed target is available at `/target`, its ESP
at `/target/boot/efi`, and the live medium at `/cdrom`. Device names and other
installation values come from `setup.conf`; changing them requires checking all
consumers before execution.

The rescue script reformats `/dev/sda1`. The root conversion encrypts
`/dev/sda3` in place. These are destructive operations.

## Priorities

Changes must prioritize, in order:

1. system bootability;
2. data integrity;
3. encryption and recovery integrity;
4. Secure Boot integrity;
5. TPM sealing integrity;
6. rollback capability;
7. maintainability;
8. user experience.

Never trade a higher-priority property for a lower-priority one without an
explicit, documented reason.

## Repository structure

- `setup.sh`: live-session and target-chroot orchestrator;
- `setup.conf.example`: versioned defaults for installation configuration;
- generated `setup.conf`: ignored secret-bearing devices, credentials and
  feature switches;
- `lib/`: framework functions genuinely shared by multiple repository scripts;
- `rescue/`: construction of the persistent Ubuntu live rescue filesystem;
- `btrfs-root/`: Btrfs subvolume conversion and in-place LUKS2 encryption;
- `secure-boot/`: sbctl keys, firmware/MOK enrollment preparation, rEFInd and
  fwupd setup;
- `btrfs-snapshots-mng/`: Snapper and the dracut snapshot selector;
- `uki/`: kernel-install, ukify, dracut and rEFInd UKI integration;
- `tpm/`: TPM configuration and standalone enrollment/status commands;
- `tests/`: non-destructive shell tests and static-validation helper;
- `docs/`: architecture, boot flow, invariants and testing documentation.

Read all files in the affected subsystem and the relevant files under `docs/`
before modifying boot, storage, encryption, signing or TPM behavior.

## Refactoring rules

Preserve existing observable behavior unless the task explicitly requests a
change. Refactor incrementally and keep unrelated behavioral changes separate.

Logic specific to one executable stays in that executable. Extract a helper to
`lib/` only when it is actually shared by multiple scripts. Do not create a
generic `common` module merely to shorten an individual script.

Shell function names use a namespace that identifies their owner:

    common.require_root
    btrfs-subvol-setup.validate_btrfs_subvolume_configuration

Use the `common.` prefix only for framework functions and a script-specific
prefix for local functions. Hyphens in Bash function names are intentional in
this repository.

The installed commands `generate-uki`, `tpm-enroll`, `tpm-reseal` and
`tpm-status` are standalone artifacts. They must continue to work after the
repository copy has been deleted and therefore must not source the repository
framework or other repository files at runtime. Their installed configuration
files may be used as documented by the scripts.

## Bash requirements

Executable shell scripts must use Bash explicitly, preferably:

    #!/usr/bin/env bash

For new or modified shell code:

- quote expansions unless splitting or globbing is intentional;
- use arrays for command argument lists;
- use `local` for function variables;
- avoid `eval`, parsing `ls`, and unnecessary subshells;
- prefer `printf` where output interpretation matters;
- handle expected command failures explicitly;
- use `set -euo pipefail` for executables when compatible with their behavior;
- do not add shell options mechanically to sourced libraries;
- keep functions focused and name them after their responsibility;
- never expose passphrases, PINs, recovery keys or private-key material in logs.

Every `cat` heredoc must keep its content visibly indented in the source. Use an
indented `<<-EOF` heredoc with leading tabs when literal output must begin in
column zero. Do not introduce unindented heredoc bodies.

Logs for installation and system-modification scripts must identify the phase,
relevant non-secret target, action and result. Fatal messages must state what
failed and, when safe, the recovery action. The main subsystem setup scripts
must finish with a truthful operation summary; do not report skipped or failed
steps as completed.

Immediately after every operational summary, run a clearly labelled
`Post-summary validation` for everything that can be checked safely at that
point. Validate produced files, mounts, configuration, executable hooks and
signatures as applicable. A required failed check must terminate the script;
never substitute validation that mutates firmware, LUKS tokens or TPM state.

Modified Bash files must pass `bash -n`, ShellCheck and the repository shfmt
style. Do not silence ShellCheck without a nearby explanation.

## Framework use

Repository-bound setup scripts should use the framework for shared concerns
that are already implemented there, including fatal errors, command
execution, cleanup, configuration loading, validation and prompts. Search
before adding a helper.

Logging is isolated in `lib/log.sh` and uses the `log.*` namespace:

    log.info "Prepare target"
    log.warn "Retrying operation"
    log.die "Target validation failed"

`log.die` preserves and reports the preceding nonzero status. When a caller has
intentionally captured safe, non-secret stderr, it may use
`log.die "message" "$command_error" "$command_status"`. Never pass captured
output blindly because commands may include credentials or private material.

Do not add logging functions back to `common.sh`. Standalone installed commands
must provide compatible local `log.*` primitives instead of sourcing `lib/`.
Keep the established color/icon semantics and leave summary values unstyled so
they remain easy to copy: `ℹ` info, `⚠` warning, `✖` error, `✔` success and
`•` summary item. Macro sections use `╔══▶ BEGIN` and `╚══■ END` banners.

Macro sections use `log.section`, which closes the previous section, rotates
the banner color and prints an explicit `BEGIN` marker. End the last section of
a flow with `log.section_end`; fatal exits close it automatically. Do not print
ad-hoc section banners that obscure these BEGIN/END boundaries.

Do not move domain logic into `lib/`. Btrfs layout decisions belong under
`btrfs-root/`; signing policy under `secure-boot/`; snapshot selection under
`btrfs-snapshots-mng/`; UKI construction under `uki/`; and TPM enrollment policy
under `tpm/`.

Separate pure transformations, argument construction and validation from
privileged execution where practical. This supports tests without touching
real devices.

## Security and boot invariants

### Storage and LUKS

- Never format, shrink, encrypt, resize or mount a device inferred from
  ambiguous input.
- Preserve recovery access and existing non-TPM keyslots unless an explicit
  operation says otherwise.
- Never pass secrets through command-line arguments when a safer input channel
  is available.
- Treat `iter_time` as an Argon2id calibration target in milliseconds, not a
  fixed iteration count; assess both password-guessing cost and unlock latency
  before changing its default.
- Keep the installed root at `@$suite/@` and check every consumer before
  changing any subvolume path.
- Treat each suite as a top-level sibling container, such as `@noble` or
  `@resolute`; never document releases as nested below `@ubuntu`.
- Keep root snapshots under `@$suite/@/.snapshots` and home snapshots under
  `@$suite/@home/.snapshots`; only root snapshots participate in snapshot boot.
- Keep the rescue partition outside LUKS; document that its persistence is not
  encrypted.
- Rescue creation runs after the target chroot phase and immediately before
  target unmount and LUKS mapper closure. It shrinks the oversized GPT rescue
  partition to at least 7168 MiB
  and creates a separate ext4 partition named and labelled `writable` in the
  released range; it must never recreate file-backed persistence.
- `setup.sh --install-rescue-live` is the standalone post-boot rescue entry
  point. It must not enter Btrfs conversion or the target chroot and may take
  its live source from `RESCUE_SOURCE_DIR`, defaulting to `/cdrom`.
- Preserve the EFI FAT filesystem label `ESP`. Relabelling must validate the
  exact device and filesystem type and must never reformat the ESP.

### Secure Boot

- Do not disable signature verification or Secure Boot as a workaround.
- Do not replace existing signing keys automatically.
- Preserve the distinction between firmware Setup Mode enrollment and the
  shim/MOK path.
- When enrolling firmware variables, the Platform Key remains last.
- rEFInd setup may remove an immediate child directory of `$ESP/EFI` only when
  that directory contains a regular file named exactly `grubefi_x64.efi`; keep
  the canonical-path and containment checks intact.
- UKIs, rEFInd, its selected drivers and fwupd executables in the trusted path
  must retain the signatures verified by the scripts.
- Preserve the Debian kernel lifecycle integration: post-install delegates to
  `kernel-install add` and must produce a db-signed, versioned UKI; post-removal
  delegates to `kernel-install remove` and removes the matching UKI.
- Keep `uki/hooks/kernel/postinst.d/debian-kernel-install-bridge` as a thin
  compatibility adapter installed under `/usr/local/libexec` and symlinked from
  both `/etc/kernel/postinst.d` and `/etc/kernel/postrm.d`. It detects the event
  from its invocation path, forwards version/image arguments with `exec`, and
  must not duplicate the UKI generation or signing implementation.
- Preserve atomic rEFInd menu regeneration after kernel add/remove. Versions
  are ordered newest-first, the newest kernel is the main/default entry, and
  pressing `Tab` on it exposes every older installed kernel as submenu entries.

### TPM

- Never clear the TPM.
- Do not change PCR policy without documenting that existing enrollments may
  stop unlocking.
- Do not enroll a TPM token during ordinary automated validation.
- Preserve password/recovery access during enrollment and resealing.
- Keep `tpm2-pin=yes` in the kernel command line even when PIN enrollment is
  disabled. This supports PINless operation while avoiding regeneration of all
  UKIs if PIN use is enabled later.

### Snapshot boot and dracut

- Normal boot must remain the fallback when the selector is not requested,
  cancelled or fails.
- A selected snapshot must be mounted read-only.
- The writable overlay must remain ephemeral.
- Do not delete snapshots as a validation side effect.
- The input listener must release devices before cryptsetup needs console input.
- Snapshot selection must happen before the real root mount and remain
  compatible with LUKS unlock.
- Preserve `/etc/snapshot-menu.conf` customization. Defaults are
  `PAGE_SIZE=20`, `DESCRIPTION_MAX_LENGTH=24`, `SNAPSHOT_TRIGGER="ALT+B"`,
  `SNAPSHOT_TRIGGER_WINDOW_TICKS=50` and
  `SNAPSHOT_TRIGGER_RESULT_TICKS=0`. Timing ticks are 100 ms, description width
  is capped at 40, and edits require UKI regeneration because the file is
  embedded in the initramfs.

## Destructive operations

Repository scripts legitimately contain destructive commands, including
filesystem creation, partition changes, LUKS reencryption, key enrollment and
EFI-variable writes. Agents may inspect and edit those paths but must not run
them on the development host.

Execution against a real block device, firmware, MOK database or TPM requires
an explicit user request and a prepared disposable or intended target. Never
use validation as permission to run destructive operations.

## Validation

Normal development validation is non-destructive:

1. parse every modified shell executable with `bash -n`;
2. run ShellCheck on every modified shell file, including extensionless files;
3. run `shfmt -d` using repository style;
4. run relevant scripts under `tests/`;
5. inspect generated text and artifact metadata without installing them;
6. inspect the final diff and check for secrets or private keys.

`tests/validate.sh` is not currently a complete repository validator: it only
searches for `*.sh`, does not cover every extensionless executable, and its
unit-test calls are disabled. Do not rely on it alone.

Never claim that boot, LUKS reencryption, firmware enrollment, MOK enrollment or
TPM unlocking works solely because static or mocked tests pass. Final reports
must distinguish verified, statically validated, inferred and not tested.

## Configuration cautions

`setup.conf` is sourced as shell code and contains passphrase/PIN values. Treat
it as secret-bearing input, replace placeholder credentials before use, never
log it wholesale and never commit real credentials.

`suite_type` selects the distribution icon used by the installed rEFInd hook;
for example, `ubuntu` selects `os_ubuntu.png` when the theme provides it.
`sb_key_dir` is not consumed by the scripts. `pre_download` and `enable_tpm`
activate only when their value is exactly `yes`. Do not document unused
variables as functional.

If `setup.conf` is missing, `setup.sh` must use `lib/tui.sh` and built-in
defaults to generate it without depending on `setup.conf.example`. Prompts are
grouped by theme and retain visible current defaults; password entry remains
hidden. Root selection is
disk-first and then limited to that disk's partitions.
Keep `mp`, `keyslot_size` and `btrfs_options` fixed and non-interactive unless a
task explicitly changes this contract. Generated configuration remains
shell-quoted, mode 0600 and atomically installed. Present `suite` as a closed
single selection (`resolute`, `noble`) and `suite_type` as a closed single
selection (currently `ubuntu`). Every `yes`/`no` question must use a toggle and
persist only the literal values `yes` or `no`.
After displaying and validating the generated configuration summary, require an
explicit toggle before installation begins. A negative answer must retain the
generated file and exit without destructive installation work.
Before collecting values, warn that setup is only for a system freshly
installed from the Ubuntu live environment and must not be presented as a
production-system migration tool.

Secure Boot setup expects `refind_themes.zip` at the repository root. Preserve
that installation artifact or change its consumer and documentation together.

## Definition of done

A change is complete only after the affected flow and callers have been read,
the smallest coherent implementation has been made, safe validation has passed,
documentation has been reconciled with actual behavior, and the final diff has
been reviewed for boot/security regressions and secret material.

## License and vulnerability reports

The repository is licensed under `GPL-3.0-only`; preserve `LICENSE` and do not
introduce incompatible third-party material. Follow `SECURITY.md` for private
vulnerability reporting and never place exploit details or secrets in a public
issue.
