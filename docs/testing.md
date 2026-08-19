# Testing

Owns validation, evidence labels and tool inventory. Tests never mutate local
disks, firmware, MOK or TPM.

## Routine validation

For each changed shell source, including extensionless commands and dracut hooks:

```bash
bash -n <file>
shellcheck -x <file>
shfmt -d <file>
```

Dracut sources hooks through `/bin/sh`; despite Bash shebangs, run `dash -n` and
keep functions/syntax Dash-compatible.

From repository root, run relevant tests:

```bash
for test_file in tests/unit/*_test.sh; do
    bash "$test_file"
done
```

Run `git diff --check`; inspect the full diff for credentials, private keys and
unintended devices.

`tests/validate.sh` is not authoritative: it resolves above the repository,
selects only `*.sh`, misses extensionless commands and skips unit tests.

## Unit-test coverage

| Test | Current focus |
| --- | --- |
| `common_test.sh` | framework and logging |
| `tui_test.sh` | prompts, defaults and generated configuration contract |
| `btrfs_root_test.sh` | subvolume paths, Kali cleanup, fstab and storage summaries |
| `new_install_test.sh` | GPT sizing, Windows gating, retry status, archive trust, mocked `sgdisk` argv, sudo-user and swapfile contracts |
| `rescue_test.sh` | sizing, persistence and optional orchestration |
| `secure_boot_test.sh` | trust-path selection, certificate export and sbctl contract |
| `snapshot_management_test.sh` | distro menu configuration, B/b trigger and installed artifacts |
| `uki_test.sh` | command line, UKI and kernel-hook behavior |
| `tpm_test.sh` | TPM configuration and enrollment argv |

Use fixtures/doubles for transformations, paths, rendering, ordering and
failures. Isolatable logic never requires root.

## Artifact checks

Safe checks inspect:

- fstab, crypttab and generated `setup.conf`;
- rescue GRUB/loopback configuration and sizing;
- public ESP certificates and absence of private material;
- kernel-install, ukify, TPM and snapshot-menu configuration;
- rEFInd ordering and UKI filename correspondence;
- UKI signature, PE sections, version and initramfs file list.

Post-summary checks inspect artifacts but never enroll keys, alter tokens,
delete snapshots or modify firmware.

Snapshot initramfs diagnostics prefix `snapshot-menu:` reports compatible evdev
discovery, matching triggers, marker, root-device resolution, menu result and
Plymouth restoration:

```bash
journalctl -b -k --no-pager | grep 'snapshot-menu:'
```

## External tools used by production scripts

Derived from `require_commands` and direct calls; builtins are omitted and
POSIX/coreutils grouped.

| Area | Tools |
| --- | --- |
| Base/orchestration | Bash, `apt`, `apt-get`, `awk`, `coreutils`, `find`, `grep`, `sed`, `util-linux`, `unshare` |
| Storage | `btrfs`, `cryptsetup`, `blkid`, `blockdev`, `debootstrap`, `findmnt`, `lsblk`, `mount`, `umount`, `fatlabel`, `mkfs.ntfs`, `parted`, `partprobe`, `sgdisk`, `udevadm` |
| Rescue | `du`, `mkfs.ext4`, `mkfs.vfat`, `partprobe`, `rsync`, `udevadm`, `xargs` |
| Secure Boot | `sbctl`, `sbverify`, `sbsign`, `mokutil`, `openssl`, `chattr`, `lsattr`, `dpkg-query`, `debconf-set-selections`, `efibootmgr`, `refind-install`, `unzip` |
| Firmware updates | `fwupdmgr`, `systemctl` when available |
| Snapshot/initramfs | `snapper`, `dracut`, `dialog`, `gcc`, `sha256sum`, dracut `getarg`, optional `plymouth` |
| UKI/kernel | `kernel-install`, `ukify`, `lsinitrd`, `objcopy`, `objdump`, `python3` |
| TPM | `systemd-cryptenroll`, `cryptsetup` |
| Dependency fallback | `git`, `curl`, `gpg`, Go toolchain, `jq`, `file` |

Setup installs/pre-downloads `dosfstools`, `e2fsprogs`,
`sbsigntool`, `systemd-ukify`, `tpm2-tools`, `tpm2-tss`, `refind`, `fwupd`,
`snapper`, `inotify-tools`, `dracut` and build dependencies. Availability varies
by distribution, suite and fallback.

## Development tools used for repository validation

- `bash` for parsing and unit tests;
- ShellCheck for static shell analysis;
- shfmt for formatting conformance;
- ripgrep (`rg`) for complete file/text discovery;
- Git for status, diff and whitespace validation.

## Destructive integration test

Use only disposable UEFI VM/hardware and non-production credentials. Exercise
new installation and post-Ubiquity/fresh-Kali migration:

1. Ubuntu snapshot conversion, Kali top-level migration, separate-boot
   migration and LUKS password recovery;
2. rescue disabled, separate rescue and accepted/declined boot reuse;
3. both Secure Boot paths, including sbctl outside Setup Mode and MOK reboot;
4. kernel install/removal and rEFInd newest/submenu behavior;
5. explicit TPM enrollment, policy-valid unlock and recovery fallback;
6. normal boot, selector cancellation and compatible read-only snapshot boot;
7. rescue boot and persistence when installed;
8. successful setup leaving target mounts and mapper open;
9. new GPT installation with root-all, root-percentage, Windows-space retry,
   Ubuntu/Kali bootstrap and SATA/NVMe device discovery.

The environment must tolerate formatting, in-place encryption and firmware/MOK
changes; static/mocked tests cannot establish bootability.

New-install unit tests mock partitioning/calculations; they do not prove a
bootstrapped, encrypted, booted or Windows-coexisting target. Destructive tests
also cover SATA/NVMe/virtual disks, archive keyrings, rescue splitting and every
supported suite.

## Reporting evidence

- **verified**: directly observed in the stated environment;
- **statically validated**: syntax/lint/format check passed;
- **unit tested**: non-privileged test passed;
- **inferred**: follows from code inspection only;
- **not tested**: requires destructive hardware, firmware or reboot testing.

Report unavailable tools and skipped destructive paths explicitly.
