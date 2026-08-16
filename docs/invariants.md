# Invariants

These invariants describe properties assumed or enforced by the current scripts.
Changing one requires tracing every producer and consumer across setup, early
boot and maintenance commands.

## Execution and disk layout

- The primary installation flow starts as root in the Ubuntu live session after
  Ubiquity has completed installation and before rebooting.
- Ubiquity uses manual partitioning.
- The default rescue, ESP and root devices are `/dev/sda1`, `/dev/sda2` and
  `/dev/sda3` respectively.
- `/dev/sda2` is the FAT32 ESP mounted at `/target/boot/efi`.
- Before target-side installation, the unmounted ESP receives the FAT filesystem
  label `ESP`; label application must not reformat it.
- `/dev/sda3` initially contains the unencrypted Ubiquity Btrfs root mounted at
  `/target`; the repository encrypts it in place.
- Before subvolume creation, the exact `root_dev` must be Btrfs and be the
  source mounted at `mp`.
- Initial target preparation preserves `/target`, `/target/boot` and
  `/target/boot/efi`; their exact sources supply wizard defaults.
- `boot_dev` is optional. Its content is copied from `$mp/boot` to
  `@$suite/@/boot`, validated, and its `/boot` fstab entry is removed without
  removing `/boot/efi`.
- The boot partition is preserved unless the user explicitly accepts its reuse
  as `rescue_dev` after the capacity check.
- `/cdrom` is the source for the rescue live environment.
- Installed-system persistent data and swap remain inside LUKS2. Its ESP is the
  only unencrypted partition in the normal boot chain; the rescue system is a
  separate unencrypted environment outside the FDE boundary.
- A device-name change in `setup.conf` must be checked against generated TPM,
  crypttab, fstab, UKI and rescue configuration.

## Rescue system

- Rescue creation requires exact target-device confirmation before formatting.
- When `rescue_dev=boot_dev`, formatting follows boot migration and an explicit
  wizard confirmation.
- The rescue target and source cannot be the same device.
- The input rescue partition is on GPT and has room for a FAT rescue range of at
  least 7168 MiB, a 256 MiB source reserve when required, and at least 512 MiB
  for a separate writable partition.
- FAT32 cannot receive an individual source file larger than 4095 MiB.
- Persistence is a separate ext4 GPT partition labelled `writable`, occupying
  the trailing range released from the original rescue partition.
- Casper boot entries contain `persistent` without duplicate insertion.
- Rescue persistence is outside LUKS and must not be described as encrypted.

## Btrfs layout

- The suite is the selected release (`resolute` or `noble`), while `suite_type`
  is the distribution family (`ubuntu`).
- The container subvolume is `@$suite` and the active root is `@$suite/@`.
- Suite containers are siblings directly below Btrfs top level `subvolid=5`, for
  example `@noble` and `@resolute`; they are never nested below `@ubuntu`.
- Root snapshots reside under `@$suite/@/.snapshots`; home snapshots reside
  under `@$suite/@home/.snapshots`. Each suite has independent histories.
- Early-boot snapshot discovery uses only the active suite's root snapshots;
  home snapshots are not boot targets.
- Dedicated subvolumes are children of the suite container:
  `@$suite/@home`, `@$suite/@cache`, `@$suite/@log`, `@$suite/@tmp`,
  `@$suite/@libvirt`, `@$suite/@docker` and `@$suite/@swap` by default.
- The swap file remains `@$suite/@swap/swapfile` by default and is created as a
  4 GiB Btrfs swap file.
- Additional suites such as `@noble` and `@resolute` require matching fstab,
  cmdline, UKI and rEFInd configuration.
- Subvolume-path changes require updating fstab generation, kernel command-line
  generation, TPM/UKI configuration and the dracut snapshot module together.
- The source top-level installation must not be deleted until its root snapshot,
  data relocation and validation have succeeded.

## LUKS and recovery

- Root encryption uses LUKS2 on the physical root partition and exposes the
  mapping as `root`.
- In-place encryption reserves 32 MiB by shrinking Btrfs before reencryption.
- `iter_time` is a positive Argon2id calibration target in milliseconds and
  defaults to 3000; it is not a literal iteration count. Increasing it raises
  both offline-guessing cost and legitimate password-operation latency.
- The generated crypttab identity is the LUKS UUID, not a volatile mapper path.
- A usable password or recovery mechanism remains available after TPM
  enrollment and resealing.
- Ordinary enrollment never removes existing LUKS keyslots or tokens.
- TPM replacement removes only TPM2 tokens and requires an explicit command-line
  acknowledgement through the reseal path.
- LUKS passphrases, PINs, recovery material and header contents never appear in
  logs.
- A header backup is created with mode 0600 before TPM token changes.

## Secure Boot

- Secure Boot is not disabled or bypassed by setup.
- Firmware Setup Mode and User Mode follow different trust paths.
- Existing firmware keys are not automatically replaced in User Mode.
- Direct firmware enrollment occurs only in Setup Mode; User Mode uses shim/MOK
  and retains the existing firmware ownership databases.
- Direct firmware enrollment orders db, KEK and PK, with PK last.
- Supported Microsoft and firmware built-in trust is retained during direct
  enrollment.
- The shim path requires a completed MOK enrollment before the local db trust
  becomes usable.
- rEFInd, its selected EFI drivers, fwupd executables and generated UKIs retain
  the signatures required by their active trust path.
- Signing keys below `/var/lib/sbctl/keys` and `/etc/uki/keys` are persistent
  private material and must not be copied into logs, tests or commits.
- Secure Boot setup is x86-64 UEFI-specific.

## UKIs

- kernel-install uses the UKI layout, dracut initrds and ukify generation.
- UKIs are installed below `/boot/efi/EFI/Linux`.
- Kernel package post-install must call `kernel-install add` and produce a UKI
  signed with the configured Secure Boot db identity; post-removal must call
  `kernel-install remove` and remove the matching versioned UKI.
- `debian-kernel-install-bridge` remains a thin lifecycle adapter installed once
  under `/usr/local/libexec` and reached through both Debian hook symlinks. It
  must forward the package version/image and propagate `kernel-install` failure
  to APT/dpkg; it must not duplicate dracut, ukify or signing logic.
- The embedded command line identifies the root LUKS UUID and Btrfs subvolume
  `@$suite/@`.
- The command line always includes
  `rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes`, including
  PINless TPM configurations.
- A generated UKI is not accepted until its db signature, required PE sections,
  embedded kernel version and applicable snapshot artifacts pass validation.
- A failed artifact is removed and the overall generation command returns
  failure after reporting all attempted kernels.
- rEFInd publishes the newest valid kernel as the main entry and older valid
  kernels as submenu entries using an atomic configuration update.
- Kernel versions remain sorted newest-first. Normal rEFInd selection boots the
  newest kernel; pressing `Tab` on that entry exposes every older installed
  version. Add/remove events must keep the UKI inventory and submenu coherent.
- `generate-uki` remains independent of the repository framework after
  installation.

## TPM

- Installing TPM support does not enroll a LUKS token automatically.
- Enrollment is an explicit post-installation action.
- `/etc/tpm.conf` is the authoritative installed TPM configuration.
- `TPM_USE_PIN=true` adds a PIN during enrollment; the default is PINless. Both
  modes keep `tpm2-pin=yes` in the embedded command line.
- The default physical LUKS device is `/dev/sda3`; mapper paths are not used for
  `systemd-cryptenroll`.
- The current policy combines the configured literal PCR expression with a
  signed PCR 11 public key.
- Changing PCR selection or PCR key material can invalidate existing automatic
  unlock and requires documented resealing.
- The TPM is never cleared by repository scripts or tests.
- `tpm-enroll`, `tpm-reseal` and `tpm-status` remain standalone after the
  repository is removed.

## Snapshot selection

- Without an Alt+B request marker, early boot follows the normal root path.
- The input listener releases input devices before cryptsetup may request a
  passphrase.
- Snapshot discovery happens after the encrypted block device is available and
  before the real root mount.
- The Btrfs top level and selected snapshot are mounted read-only.
- Snapshot boot never writes to or deletes the selected snapshot.
- Runtime writes use an ephemeral dracut overlay.
- A snapshot must contain modules for the running kernel.
- Cancellation, authentication failure and menu errors fall back to normal
  boot.
- The menu PIN is only an accidental-selection guard; it is not an encryption or
  authentication boundary, and current-system selection bypasses it.
- `/etc/snapshot-menu.conf` owns the customizable menu defaults:
  `PAGE_SIZE=20`, `DESCRIPTION_MAX_LENGTH=24`, `SNAPSHOT_TRIGGER="ALT+B"`,
  `SNAPSHOT_TRIGGER_WINDOW_TICKS=50` and
  `SNAPSHOT_TRIGGER_RESULT_TICKS=0`.
- Page size and description length stay positive, description length is capped
  at 40, and timing values are non-negative 100 ms ticks. Configuration changes
  require UKI regeneration because the file is embedded in the initramfs.

## Framework and installed artifacts

- Domain-specific logic remains in its subsystem scripts.
- Only functions shared by multiple repository scripts belong under `lib/`.
- Shared logging lives only in `lib/log.sh` and is invoked through `log.*`;
  `common.sh` must not become a second logging implementation.
- Function names identify their owner, for example `common.require_root` or
  `tpm-enroll.load_configuration`.
- `generate-uki`, `tpm-enroll`, `tpm-reseal` and `tpm-status` have no runtime
  dependency on the repository or its framework.
- Every `cat` heredoc is visibly indented in source; tab-stripping heredocs are
  used when generated content must begin in column zero.
- Installation scripts log phases and outcomes without leaking secrets and end
  their subsystem flow with an accurate summary where implemented as a primary
  setup command.

## Configuration truth

- `setup.conf` is sourced shell input and may contain secrets.
- `setup.conf.example` is a versioned reference only. Wizard defaults are
  built into `setup.sh`, while `setup.conf` is generated locally and excluded
  from Git; configuration generation must not depend on the example file.
- When absent, it is generated only through the interactive TUI and installed
  atomically with mode 0600. `mp`, `keyslot_size` and `btrfs_options` retain
  their repository defaults and are not prompted.
- Exact mounts at `/target`, `/target/boot/efi` and `/target/boot` provide
  `root_dev`, `efi_dev`, optional `boot_dev` and `mp` defaults.
- The guided flow restricts `suite` to `resolute` or `noble` and `suite_type`
  to the currently supported `ubuntu` value. All `yes`/`no` questions use
  toggles and persist only those literal values.
- Wizard prompts remain grouped by storage, distribution, security and optional
  features. Installation begins only after the generated summary, its
  validation and an explicit affirmative toggle.
- The wizard must warn before input collection that the conversion targets a
  freshly installed system and is unsuitable for an existing production host.
- Placeholder credentials are replaced before real execution and real
  credentials are never committed.
- Feature flags `pre_download` and `enable_tpm` activate only for literal `yes`.
- `suite_type` selects `os_<suite_type>.png` for rEFInd, with a generic Linux
  fallback. `sb_key_dir` currently has no behavioral effect.
- `refind_themes.zip` remains available at the repository root for Secure Boot
  setup.
