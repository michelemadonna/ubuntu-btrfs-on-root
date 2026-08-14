# Architecture

## Scope

This repository is a post-installation converter, not an Ubuntu installer. The
operating system is first installed by Ubiquity from an Ubuntu live session.
Without rebooting, `setup.sh` is then run as root from that same live session.

The supported default disk layout is:

| Partition | Ubiquity/setup role | Result |
| --- | --- | --- |
| `/dev/sda1` | oversized partition reserved for rescue | FAT32 Ubuntu live copy, at least 7168 MiB |
| `/dev/sda2` | `/boot/efi` | FAT filesystem labelled `ESP`, containing rEFInd, shim when required, fwupd and UKIs |
| `/dev/sda3` | `/` formatted as Btrfs | in-place LUKS2 container with the Btrfs subvolume layout |

All persistent data of the installed system—including root, home, logs,
containers and swap—is inside LUKS2. The ESP is its only unencrypted partition
in the normal boot chain. `/dev/sda1` is a separate unencrypted rescue system
outside that FDE boundary.

Ubiquity must use manual partitioning. `/dev/sda3` must initially be Btrfs and
must not already be encrypted by Ubiquity, because this repository performs the
in-place LUKS2 conversion. `/dev/sda2` must be the FAT32 ESP. `/dev/sda1` must be
large enough for a FAT rescue area of at least 7168 MiB and a separate ext4
persistence partition of at least 512 MiB.

The live environment is expected at `/cdrom`, Ubiquity's installed root at
`/target`, and its ESP at `/target/boot/efi`. The defaults are defined in
`setup.conf`.

During the `btrfs-root` phase, setup verifies that `/dev/$efi_dev` is an
unmounted FAT filesystem, assigns it the filesystem label `ESP` with `fatlabel`
and confirms the result through `blkid`. It does not reformat the ESP.

## Orchestration boundary

`setup.sh` has two execution phases:

1. The outer phase runs in the live system. It converts and encrypts the
   installed Btrfs root, prepares bind mounts, copies the repository into the
   target and enters a mount-isolated chroot. After the chroot returns it creates
   the rescue system, then performs target unmount and LUKS mapper cleanup.
2. The `//inner` phase runs inside the installed system. It configures Secure
   Boot, snapshots, UKIs and optional TPM integration, then returns to the outer
   phase for cleanup.

The chroot is launched through `unshare --mount --fork`. The outer phase binds
the host resources needed by the installed system and later recursively
unmounts the target and closes the `root` LUKS mapping.

Before either phase, a missing `setup.conf` activates the guided configuration
flow implemented with `lib/tui.sh`. Disk and partition choices come from
`lsblk`; root selection is scoped to the previously selected disk. Defaults are
built into `setup.sh` so configuration generation does not depend on the
example file, and inputs are grouped by storage,
distribution, security and optional features. The wizard
writes shell-quoted values atomically with mode 0600 and validates the resulting
syntax, permissions and required assignments. `suite` is selected from
`resolute` and `noble`; `suite_type` currently exposes only `ubuntu`. Boolean
configuration uses `yes`/`no` toggles. Mount point, LUKS header reservation and
Btrfs options remain fixed implementation defaults rather than interactive
choices. After the generated values and post-summary validation are shown, an
explicit toggle controls whether installation starts; declining retains
`setup.conf` and exits without entering the destructive installation flow.

The target-side repository copy is an installation input, not a permanent
runtime dependency. Four commands are deliberately installed as autonomous
artifacts:

- `/usr/local/sbin/generate-uki`;
- `tpm-enroll`;
- `tpm-reseal`;
- `tpm-status`.

They do not source the repository framework at runtime and must remain usable
after the repository directory is removed.

Shared repository logging is implemented by `lib/log.sh` through the `log.*`
namespace. `lib/common.sh` sources that module and contains validation and other
non-logging helpers. Standalone installed commands embed compatible `log.*`
primitives so this separation does not create a runtime repository dependency.
Colored icons distinguish repository logs from raw command output; summary
labels are styled while their values remain plain text.
Macro-section banners rotate colors and use paired `BEGIN`/`END` markers. A new
section automatically closes the previous one, while final post-summary
validation sections are closed explicitly.

## Rescue subsystem

`rescue/script/install-rescue-live` builds `/dev/sda1` from the live medium's
`/cdrom/casper` tree. It requires explicit confirmation of the target device and
then:

1. validates source and destination sizes;
2. shrinks its leading partition range to the larger of 7168 MiB or the live
   source size plus 256 MiB;
3. creates a new GPT partition in the released trailing range, formats it ext4
   and labels it `writable`;
4. formats the resized rescue partition FAT32 with label `UBUNTU_LIVE`;
5. copies the live medium without copying symbolic links and excludes an
   existing `writable` path;
6. adds the `persistent` kernel option to Casper entries in `grub.cfg` and
   `loopback.cfg`.

The writable partition consumes the remaining original rescue range and must be
at least 512 MiB. A single live source file above 4095 MiB is still rejected
because the live files themselves are copied to FAT32.

This rescue environment is outside the root LUKS container. Its persistence is
therefore not protected by root-disk encryption.

`setup.sh --install-rescue-live` exposes the rescue subsystem as an independent
post-boot operation. It loads `rescue_dev` from the normal configuration,
accepts `RESCUE_SOURCE_DIR` as an optional live-source override (default
`/cdrom`) and delegates directly to the rescue installer without running Btrfs
conversion or entering the target chroot.

## Btrfs and LUKS subsystem

`btrfs-root/scripts/btrfs-root-setup` transforms the Ubiquity filesystem. The
suite name is `ubuntu`, so the root container is `@ubuntu` and the active root is
`@ubuntu/@`.

The script snapshots the original top-level filesystem into `@ubuntu/@`, creates
dedicated subvolumes inside `@ubuntu` and relocates data where required:

- `@ubuntu/@home` for `/home`;
- `@ubuntu/@cache` for `/var/cache`;
- `@ubuntu/@log` for `/var/log`;
- `@ubuntu/@tmp` for `/var/tmp`;
- `@ubuntu/@libvirt` for `/var/lib/libvirt`;
- `@ubuntu/@docker` for `/var/lib/docker`;
- `@ubuntu/@swap` containing a 4 GiB Btrfs swap file.

Multiple suites are siblings directly below the Btrfs top level (`subvolid=5`),
not children of `@ubuntu`. For example, `@noble/@` and `@resolute/@` can coexist,
with `@noble/@home` and `@resolute/@home` beside their respective roots. The
configured `$suite` determines the container created by one setup invocation.
Each suite requires coherent fstab, UKI and rEFInd configuration.

Snapper isolation follows the same boundary. Root snapshots for a suite are
under `@$suite/@/.snapshots`, while home snapshots are under
`@$suite/@home/.snapshots`. Thus Noble and Resolute maintain independent root
and home histories. The early-boot menu consumes only the active suite's root
snapshots; home snapshots are not boot targets.

After the subvolume copy has succeeded, the original top-level installation
content is removed while `@`-prefixed subvolumes are retained.

Encryption is performed in place. The Btrfs filesystem is shrunk by 32 MiB,
unmounted and passed to `cryptsetup reencrypt` as LUKS2 with Argon2id, the
configured `iter_time` target (3000 ms by default) and a 32 MiB reduced device
size. `--iter-time` is a calibration target in milliseconds, not a literal
iteration count: cryptsetup selects Argon2id parameters intended to consume
approximately that duration on the setup machine. The resulting device is
opened as `/dev/mapper/root`, the filesystem is mounted through that mapping and
resized to its maximum.

Optional partition enlargement runs before conversion only when `enlarge=yes`.
The default is `no`.

The generated crypttab entry is equivalent to:

    root UUID=<LUKS-UUID> none luks,discard

The installer-created root entry in `fstab` must match the exact Btrfs root-line
shape expected by the rewrite code. The script replaces it and appends the
subvolume and swap mounts.

## Secure Boot subsystem

Secure Boot setup runs inside the target chroot and requires UEFI on x86-64. It
reads firmware `SetupMode` and `SecureBoot`, stores the initially detected setup
mode in `/etc/securebootmode.conf`, and creates or reuses sbctl PK, KEK and db
keys below `/var/lib/sbctl/keys`.

There are two boot trust paths:

- Firmware Setup Mode (`SetupMode=1`): keys are enrolled directly into firmware.
  db is enrolled first, then KEK, and PK last. Supported Microsoft and firmware
  built-in certificates are retained.
- Existing User Mode (`SetupMode=0`): firmware enrollment is skipped. The system
  uses shim and imports the db certificate through MOK, requiring the user to
  complete enrollment at the next reboot.

Direct sbctl firmware enrollment is selected only in Setup Mode. It provides a
shorter locally controlled chain, but makes firmware-key backup and recovery the
administrator's responsibility. User Mode preserves existing OEM/Microsoft
firmware ownership through shim/MOK, but adds a shim layer and requires an
interactive MOK enrollment. sbctl signs local artifacts in both modes; only the
Setup Mode path enrolls its keys directly into firmware db.

rEFInd becomes the primary loader. In the direct path, signed `refind_x64.efi`
is also installed as the fallback `BOOTX64.EFI`. In the shim path, shim occupies
the first-stage location and the rEFInd payload is placed at the filename used by
the shim installer, with MokManager available beside it. Selected rEFInd drivers
and fwupd EFI binaries are signed with the repository-created db key and
verified.

Before installing rEFInd, setup inspects only the immediate child directories
of the ESP's `EFI` directory. Any such directory containing a regular file named
exactly `grubefi_x64.efi` anywhere below it is treated as obsolete and removed
in full. Unrelated EFI directories and similarly named files are retained.

When Ubuntu packages are unsuitable for the selected path, shim and rEFInd are
obtained from the pinned Debian snapshot dated 2026-08-12 and authenticated with
the Debian archive keyring. The repository does not use an unauthenticated
`trusted=yes` source.

The setup code expects the included `refind_themes.zip` archive at the
repository root.

## Snapshot subsystem

The snapshot manager installs Snapper configurations for root and home, enables
timeline snapshots, grants the configured administrative group access and
configures Btrfs maintenance tools. The early-boot selector is optional through
`snapshot_menu`, which defaults to `yes`.

The selector is installed as dracut module
`/usr/lib/dracut/modules.d/92snapshot-menu`. A compiled input listener watches
TTY1 for Alt+B during a five-second trigger window. A systemd cryptsetup drop-in
starts it before unlocking and makes the listener release input devices before
cryptsetup can prompt.

This early-boot selector is a unique project feature. It runs after LUKS becomes
available but before the real root mount and offers the current system,
compatible snapshots, metadata and descriptions, pagination, cancellation and
an optional PIN.

When requested, a pre-mount hook mounts the Btrfs top level read-only, discovers
Snapper root snapshots below `@/.snapshots/<number>/snapshot` for the active
suite, and offers the current system plus compatible snapshots. A snapshot
lacking modules for the running
kernel is rejected. The selected snapshot is mounted read-only as the new root,
while dracut supplies a temporary overlay for runtime writes. Cancelling or any
selection failure falls back to normal root boot.

The optional selector PIN is stored as a salted SHA-256 value embedded in the
initramfs, allows three attempts and has a maximum length of 12. It is an
accidental-selection guard, not a cryptographic boundary; selecting the current
system bypasses it.

## UKI subsystem

The UKI installer configures systemd kernel-install with `layout=uki`, dracut as
the initrd generator and ukify as the UKI generator. Configuration is stored in
`/etc/kernel/install.conf`, `/etc/kernel/entry-token`, `/etc/kernel/uki.conf`
and a link at `/etc/systemd/ukify.conf`.

ukify uses the Secure Boot db key/certificate, the kernel command line, OS
release metadata, a Plymouth-derived BMP splash and persistent RSA PCR keys
below `/etc/uki/keys`. PCR signing covers the configured initrd phases. UKIs are
written under `/boot/efi/EFI/Linux`.

The kernel command line identifies both the LUKS UUID and `@ubuntu/@`, includes
the configured Btrfs mount options, disables the dracut recovery shell, and uses
quiet splash boot. TPM integration normalizes this option unconditionally:

    rd.luks.options=tpm2-device=auto,tpm2-measure-pcr=yes,tpm2-pin=yes

`tpm2-pin=yes` remains present even for PINless enrollment so enabling a PIN
later does not require rebuilding all UKIs.

Kernel package post-install and removal hooks delegate to `kernel-install`.
After generation, `generate-uki` verifies the db signature, required PE sections,
embedded kernel version and, when configured, snapshot-menu initramfs content.
Invalid UKIs are removed. rEFInd configuration is regenerated atomically with
the newest version as the primary entry and older versions in a submenu.
The hook reads `suite_type` from `/etc/kernel/refind-icon` to select
`os_<suite_type>.png`, with a generic Linux icon fallback.

## TPM subsystem

TPM installation creates `/etc/tpm.conf` and installs the standalone commands;
it does not enroll the disk automatically. Enrollment is a later explicit
operation through `tpm-enroll` or the corresponding `setup.sh` maintenance
option.

The default configuration targets physical device `/dev/sda3`, uses automatic
TPM selection, disables a user PIN and combines a literal PCR policy with signed
PCR 11 policy material. Setting `TPM_USE_PIN="true"` in `/etc/tpm.conf` before
enrollment adds a knowledge factor. It improves protection if the complete
machine is stolen, but prevents unattended boot. Enrollment first creates a
uniquely named, mode-0600 LUKS header backup under `/var/backups/luks`.

Normal enrollment preserves existing password, recovery and TPM access.
`--wipe-existing-tpm2` replaces only existing TPM2 tokens. `tpm-reseal` requires
the explicit `--wipe-all-tpm2` acknowledgement and delegates to that replacement
path; it does not remove password or recovery keyslots.

## Configuration reality

`setup.conf.example` is executable shell configuration containing the versioned
defaults and placeholder credentials. `setup.conf` is the generated,
secret-bearing runtime configuration and must remain protected. `pre_download`
and `enable_tpm` are enabled only by the literal value `yes`. `suite_type`
selects the distribution icon used by rEFInd; the default `ubuntu` selects
`os_ubuntu.png`. `sb_key_dir` currently has no script consumer.
