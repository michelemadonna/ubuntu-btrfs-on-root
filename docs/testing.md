# Testing

## Scope and safety boundary

The repository changes partitioning, filesystems, LUKS metadata, firmware keys,
MOK state and TPM tokens. Normal development validation must not execute those
operations against the workstation or an unintended disk.

Testing is divided into:

1. static validation of shell source;
2. non-privileged unit tests using mocks and fixtures;
3. inspection of generated configuration and UKI/initramfs artifacts;
4. destructive integration and boot testing in an explicitly prepared machine
   or disposable virtual environment.

Only the first three categories are safe for routine agent execution. Passing
them does not prove that the installed system boots or that firmware, MOK, LUKS
or TPM operations succeed on hardware.

## Current automated tests

The `tests/unit/` directory contains subsystem-oriented shell tests:

- `common_test.sh` for shared framework behavior;
- `btrfs_root_test.sh` for storage logic;
- `rescue_test.sh` for rescue sizing and configuration behavior;
- `secure_boot_test.sh` for Secure Boot logic;
- `snapshot_management_test.sh` for snapshot-menu behavior;
- `tpm_test.sh` for TPM argument/configuration logic;
- `uki_test.sh` for UKI behavior.

Run the relevant tests directly with Bash from the repository root. They are
intended to avoid privileged host modification through test doubles and
fixtures. Inspect a test before running it if its implementation has changed.

`tests/validate.sh` is not a complete validation entry point in its current
form. Its repository-root calculation ascends beyond this repository when run
from `tests/`, it only discovers files matching `*.sh`, and its unit-test calls
are commented out. Consequently it misses extensionless production commands
and must not be used as evidence that the whole repository passed validation.

## Static validation

For every changed shell file, including scripts without a `.sh` suffix and
dracut `.install`/hook files where applicable, run:

    bash -n <file>
    shellcheck <file>
    shfmt -d <file>

Do not construct the file list from `*.sh` alone. Use the tracked executable
inventory and shebangs so that commands such as `setup.sh`, `generate-uki`, TPM
commands, subsystem setup commands and dracut hooks are included.

Sourced libraries should be parsed independently, but their runtime behavior
must also be tested through a controlled caller because shell options and traps
are inherited from that caller.

## Unit-test targets

Prefer tests of deterministic transformations and decisions:

- setup configuration validation and device-name construction;
- `log.*` output channels, formatting and fatal-exit behavior;
- rescue source/destination sizing and FAT32/persistence limits;
- Btrfs subvolume and fstab/crypttab model generation;
- Secure Boot mode detection and enrollment ordering;
- rEFInd path and configuration selection for direct and shim modes;
- version ordering and UKI path generation;
- `suite_type` propagation and rEFInd distribution-icon fallback;
- kernel command-line normalization, especially the single unconditional
  `tpm2-pin=yes` option;
- TPM enrollment argv construction with and without replacement of TPM tokens;
- TPM enrollment arguments for PINless and PIN-required modes;
- snapshot discovery, compatibility filtering, pagination and fallback choices.

Mock host-facing tools such as:

- `lsblk`, `findmnt`, `blkid`, `parted` and `btrfs`;
- `cryptsetup` and `systemd-cryptenroll`;
- `sbctl`, `mokutil`, `bootctl` and EFI-variable reads;
- `snapper`, `dracut`, `ukify`, `kernel-install` and `sbsign`;
- TPM utilities and input-device discovery.

Tests must never require root merely to validate pure logic.

## Artifact validation

Generated configuration can be checked safely in a temporary tree. Relevant
artifacts include:

- fstab and crypttab entries;
- rescue GRUB and loopback entries with one `persistent` option;
- `/etc/kernel/install.conf`, entry token, ukify config and kernel command line;
- `/etc/tpm.conf` and header-backup path construction;
- rEFInd configuration and version ordering;
- dracut module file list and systemd cryptsetup drop-in;
- UKI PE sections, signature, embedded kernel version and extracted initramfs
  file list.

Artifact tests may inspect or extract a prebuilt sample. They must not install
it into the workstation ESP, sign with production private keys, enroll a key or
modify EFI variables.

## Required destructive integration environment

End-to-end testing needs a dedicated UEFI-capable target that mirrors the real
workflow:

1. boot an Ubuntu live image in UEFI mode;
2. use Ubiquity manual partitioning;
3. create `/dev/sda1` for rescue, `/dev/sda2` as the FAT32 ESP and `/dev/sda3`
   as the unencrypted Btrfs root;
4. finish installation and remain in the live session;
5. supply non-production setup credentials and the required
   `refind_themes.zip` artifact included at the repository root;
6. run setup and preserve complete non-secret logs;
7. reboot through the applicable direct-firmware or shim/MOK path;
8. validate password recovery before and after TPM enrollment;
9. enroll TPM explicitly, then test policy-valid unlock and recovery fallback;
10. test normal boot, Alt+B cancellation, current-system selection and a
    compatible read-only snapshot with ephemeral writes;
11. boot the rescue partition and verify persistence separately.

Use disposable virtual disks or hardware intentionally allocated to the test.
The test destroys the rescue partition, transforms the root partition and may
modify firmware or MOK state. TPM behavior may require a virtual TPM or a
dedicated physical target.

## Failure and recovery checks

Integration testing should also exercise controlled failures:

- incorrect setup device mapping must fail before destructive execution;
- insufficient rescue capacity and oversized FAT32 source files must fail;
- an unavailable signing key or invalid EFI signature must prevent artifact
  acceptance;
- a UKI missing a required section or snapshot initramfs component must be
  removed and reported as failed;
- invalid TPM policy must fall back to retained password/recovery access;
- a snapshot without the running kernel modules must be rejected;
- snapshot listener/menu failures must continue with normal boot;
- interrupted setup must leave logs sufficient to identify the completed phase
  without displaying credentials.

## Reporting

Validation reports must label results precisely:

- **verified**: directly observed in the stated test environment;
- **statically validated**: syntax, lint or formatting check passed;
- **unit tested**: mocked/non-privileged behavior passed;
- **inferred**: follows from code inspection but was not executed;
- **not tested**: requires destructive hardware, firmware or reboot testing.

Never summarize static success as proof of a bootable system. Record skipped
tools, unavailable dependencies and every destructive path that was not run.
