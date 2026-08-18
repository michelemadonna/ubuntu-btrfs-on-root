# Testing

This document owns validation procedure, evidence labels and the external-tool
inventory. Tests must not mutate workstation disks, firmware, MOK or TPM state.

## Routine validation

For every changed shell source, including extensionless commands and dracut
hooks:

```bash
bash -n <file>
shellcheck -x <file>
shfmt -d <file>
```

Dracut sources hook files through `/bin/sh` regardless of their shebang. Run
`dash -n` on sourced hooks as well; function names and syntax must therefore be
accepted by Dash even when the hook file declares Bash.

Run relevant tests directly from the repository root:

```bash
for test_file in tests/unit/*_test.sh; do
    bash "$test_file"
done
```

Then run `git diff --check`, inspect the full diff and search for credentials,
private keys and unintended device paths.

`tests/validate.sh` is not authoritative: its root calculation currently walks
above this repository, it selects only `*.sh`, misses extensionless commands and
does not execute the unit tests.

## Unit-test coverage

| Test | Current focus |
| --- | --- |
| `common_test.sh` | framework and logging |
| `tui_test.sh` | prompts, defaults and generated configuration contract |
| `btrfs_root_test.sh` | subvolume paths, fstab and storage summaries |
| `rescue_test.sh` | sizing, persistence and optional orchestration |
| `secure_boot_test.sh` | trust-path selection, certificate export and sbctl contract |
| `snapshot_management_test.sh` | menu configuration and fallback behavior |
| `uki_test.sh` | command line, UKI and kernel-hook behavior |
| `tpm_test.sh` | TPM configuration and enrollment argv |

Prefer fixtures and command doubles for transformations, path selection,
configuration rendering, ordering and failure propagation. Never require root
for logic that can be isolated.

## Artifact checks

Safe checks may inspect temporary or prebuilt artifacts:

- fstab, crypttab and generated `setup.conf`;
- rescue GRUB/loopback configuration and sizing calculations;
- public ESP certificates and absence of private material;
- kernel-install, ukify, TPM and snapshot-menu configuration;
- rEFInd ordering and UKI filename correspondence;
- UKI signature, PE sections, embedded version and initramfs file list.

Post-summary validation may inspect current artifacts, but must not enroll keys,
alter tokens, delete snapshots or modify firmware.

Snapshot-menu initramfs diagnostics are written to the kernel journal with the
`snapshot-menu:` prefix. After a boot, inspect the listener, request marker,
root-device resolution, menu result and Plymouth restoration with:

```bash
journalctl -b -k --no-pager | grep 'snapshot-menu:'
```

## External tools used by production scripts

This inventory is derived from current `require_commands` checks and direct
invocations. Shell builtins are omitted; common POSIX/coreutils text and file
commands are grouped.

| Area | Tools |
| --- | --- |
| Base/orchestration | Bash, `apt`, `apt-get`, `awk`, `coreutils`, `find`, `grep`, `sed`, `util-linux`, `unshare` |
| Storage | `btrfs`, `cryptsetup`, `blkid`, `blockdev`, `findmnt`, `lsblk`, `mount`, `umount`, `fatlabel`, `parted` |
| Rescue | `du`, `mkfs.ext4`, `mkfs.vfat`, `partprobe`, `rsync`, `udevadm`, `xargs` |
| Secure Boot | `sbctl`, `sbverify`, `sbsign`, `mokutil`, `openssl`, `chattr`, `lsattr`, `dpkg-query`, `debconf-set-selections`, `efibootmgr`, `refind-install`, `unzip` |
| Firmware updates | `fwupdmgr`, `systemctl` when available |
| Snapshot/initramfs | `snapper`, `dracut`, `dialog`, `gcc`, `sha256sum`, dracut `getarg`, optional `plymouth` |
| UKI/kernel | `kernel-install`, `ukify`, `lsinitrd`, `objcopy`, `objdump`, `python3` |
| TPM | `systemd-cryptenroll`, `cryptsetup` |
| Dependency fallback | `git`, `curl`, Go toolchain, `jq`, `file` |

Package names installed/pre-downloaded by setup include providers such as
`dosfstools`, `e2fsprogs`, `sbsigntool`, `systemd-ukify`, `tpm2-tools`,
`tpm2-tss`, `refind`, `fwupd`, `snapper`, `inotify-tools`, `dracut` and build
dependencies.
Availability still depends on the selected Ubuntu suite and fallback paths.

## Development tools used for repository validation

- `bash` for parsing and unit tests;
- ShellCheck for static shell analysis;
- shfmt for formatting conformance;
- ripgrep (`rg`) for complete file/text discovery;
- Git for status, diff and whitespace validation.

## Destructive integration test

Use only a disposable UEFI VM or explicitly allocated hardware. Reproduce the
post-Ubiquity live-session state, use non-production credentials and exercise:

1. Btrfs conversion, separate-boot migration and LUKS password recovery;
2. optional rescue disabled, separate rescue, and accepted/declined boot reuse;
3. both Secure Boot paths, including sbctl outside Setup Mode and MOK reboot;
4. kernel install/removal and rEFInd newest/submenu behavior;
5. explicit TPM enrollment, policy-valid unlock and recovery fallback;
6. normal boot, selector cancellation and compatible read-only snapshot boot;
7. rescue boot and persistence when installed;
8. successful setup leaving target mounts and mapper open.

The environment must tolerate partition formatting, in-place encryption and
firmware/MOK changes. Static and mocked tests cannot establish bootability.

## Reporting evidence

- **verified**: directly observed in the stated environment;
- **statically validated**: syntax/lint/format check passed;
- **unit tested**: non-privileged test passed;
- **inferred**: follows from code inspection only;
- **not tested**: requires destructive hardware, firmware or reboot testing.

Report unavailable tools and skipped destructive paths explicitly.
