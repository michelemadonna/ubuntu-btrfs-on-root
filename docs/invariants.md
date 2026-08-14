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
- `/dev/sda3` initially contains the unencrypted Ubiquity Btrfs root mounted at
  `/target`; the repository encrypts it in place.
- `/cdrom` is the source for the rescue live environment.
- Installed-system persistent data and swap remain inside LUKS2. Its ESP is the
  only unencrypted partition in the normal boot chain; the rescue system is a
  separate unencrypted environment outside the FDE boundary.
- A device-name change in `setup.conf` must be checked against generated TPM,
  crypttab, fstab, UKI and rescue configuration.

## Rescue system

- Rescue creation requires exact target-device confirmation before formatting.
- The rescue target and source cannot be the same device.
- The rescue partition is at least 4096 MiB and has room for the live source,
  256 MiB reserve and at least 512 MiB persistence.
- FAT32 cannot receive an individual source file larger than 4095 MiB.
- The persistence file is ext4, at least 512 MiB and no larger than 4095 MiB.
- Casper boot entries contain `persistent` without duplicate insertion.
- Rescue persistence is outside LUKS and must not be described as encrypted.

## Btrfs layout

- The suite is `ubuntu`.
- The container subvolume is `@ubuntu` and the active root is `@ubuntu/@`.
- Suite containers are siblings directly below Btrfs top level `subvolid=5`, for
  example `@noble` and `@resolute`; they are never nested below `@ubuntu`.
- Root snapshots reside under `@$suite/@/.snapshots`; home snapshots reside
  under `@$suite/@home/.snapshots`. Each suite has independent histories.
- Early-boot snapshot discovery uses only the active suite's root snapshots;
  home snapshots are not boot targets.
- Dedicated subvolumes are children of the distribution container:
  `@ubuntu/@home`, `@ubuntu/@cache`, `@ubuntu/@log`, `@ubuntu/@tmp`,
  `@ubuntu/@libvirt`, `@ubuntu/@docker` and `@ubuntu/@swap` by default.
- The swap file remains `@ubuntu/@swap/swapfile` by default and is created as a
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
- The embedded command line identifies the root LUKS UUID and Btrfs subvolume
  `@ubuntu/@`.
- The command line always includes
  `rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes`, including
  PINless TPM configurations.
- A generated UKI is not accepted until its db signature, required PE sections,
  embedded kernel version and applicable snapshot artifacts pass validation.
- A failed artifact is removed and the overall generation command returns
  failure after reporting all attempted kernels.
- rEFInd publishes the newest valid kernel as the main entry and older valid
  kernels as submenu entries using an atomic configuration update.
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
- Placeholder credentials are replaced before real execution and real
  credentials are never committed.
- Feature flags `pre_download` and `enable_tpm` activate only for literal `yes`.
- `suite_type` selects `os_<suite_type>.png` for rEFInd, with a generic Linux
  fallback. `sb_key_dir` currently has no behavioral effect.
- `refind_themes.zip` remains available at the repository root for Secure Boot
  setup.
