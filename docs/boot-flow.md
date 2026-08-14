# Boot Flow

## 1. Purpose

This document describes the runtime boot sequence of the system.

It defines the ordering and responsibilities of:

- UEFI firmware
- Secure Boot
- shim / MOK when required
- rEFInd
- Unified Kernel Image (UKI)
- Linux kernel
- dracut initramfs
- snapshot-menu trigger
- TPM2 / LUKS unlock
- snapshot selection
- Btrfs root selection
- OverlayFS snapshot boot
- switch_root

This document describes runtime behavior.

System architecture is documented in `docs/architecture.md`.
Security and boot invariants are documented in `docs/invariants.md`.

## 2. Complete boot flow

### 2.1 Installation-established state

Before the runtime boot flow can succeed, the live installer establishes the
following persistent state exactly once:

- the configured Btrfs root and data subvolumes;
- a LUKS2 container opened at `/dev/mapper/root`;
- target `/etc/crypttab` using the post-encryption LUKS UUID;
- target `/etc/fstab` using `/dev/mapper/root` and the configured subvolumes;
- a swapfile inside the configured `@swap` subvolume.
- an independent persistent Ubuntu live rescue system on the configured
  FAT32 rescue partition.

The package and boot-artifact phases then run inside the target chroot. They
must not repeat the destructive storage phase. At runtime, dracut consumes
the resulting LUKS mapping and Btrfs root configuration described below.

### 2.2 Rescue boot path

The rescue partition is an independent UEFI live-medium path. Firmware boots
the copied Ubuntu live loader and GRUB configuration rather than the installed
rEFInd/UKI chain. Casper sees the idempotently added `persistent` option and
uses the ext4 filesystem stored in the FAT32 `writable` file.

The rescue environment remains usable when the installed LUKS root, UKIs or
rEFInd configuration cannot boot. Its persistence is not LUKS-encrypted, so
unlocking or repairing the installed root still requires normal recovery
credentials and no secrets should be stored persistently in the rescue system.

### 2.3 Installed-system runtime sequence

The complete boot process is:

    Power on
       |
       v
    UEFI firmware
       |
       v
    Secure Boot verification
       |
       +---------------------------+
       |                           |
       v                           v
    direct trust               shim path
       |                           |
       |                          shim
       |                           |
       |                         MOK
       |                           |
       +-------------+-------------+
                     |
                     v
                   rEFInd
                     |
                     v
                    UKI
                     |
              +------+------+
              | kernel      |
              | initrd      |
              | cmdline     |
              | PCR data    |
              +------+------+
                     |
                     v
                Linux kernel
                     |
                     v
               dracut initramfs
                     |
                     v
           snapshot trigger window
                     |
             +-------+-------+
             |               |
        not requested     requested
             |               |
             |          request marker
             |               |
             +-------+-------+
                     |
                     v
                TPM2 / LUKS
                   unlock
                     |
                     v
             encrypted Btrfs
                available
                     |
             +-------+-------+
             |               |
        normal boot      snapshot requested
             |               |
             |               v
             |        discover snapshots
             |               |
             |               v
             |          snapshot menu
             |               |
             |               v
             |       selected snapshot
             |               |
             |               v
             |       configure snapshot
             |          root + overlay
             |               |
             +-------+-------+
                     |
                     v
                root mount
                     |
                     v
                switch_root
                     |
                     v
                  systemd

## 3. Secure Boot entry
The firmware is the initial root of trust.
Before executing the Linux boot chain, the installer may have configured
one of two supported trust paths.
### 3.1 Direct trust path
When the project has configured direct firmware trust:
	UEFI
	  |
	  | verify
	  v
	rEFInd
	  |
	  | verify
	  v
	 UKI
rEFInd is signed using a key accepted by the firmware Secure Boot
configuration.
No shim component participates in this path.

The directly installed `refind_x64.efi` and fallback `BOOTX64.EFI` copy are
signed with the repository db key. Verification checks `refind_x64.efi`
against the corresponding db certificate.

### 3.2 shim trust path
When the project uses the existing firmware trust hierarchy:
	UEFI
	  |
	  | verify using firmware db
	  v
	 shim
	  |
	  | verify through MOK trust
	  v
	rEFInd
	  |
	  | verify
	  v
	 UKI

shim provides the bridge between firmware-established trust and
repository-managed signing keys.

`refind-install --shim` places the repository-signed rEFInd payload behind
shim as `grubx64.efi`. The concrete chain is:

    firmware db -> shimx64.efi -> MOK db certificate -> grubx64.efi

MokManager remains the vendor-signed enrollment component. Repository
signature verification targets `grubx64.efi`, not `shimx64.efi`.

fwupd follows the same selected path: direct mode disables shim for capsule
loading, while shim/MOK mode retains shim in the fwupd chain.

Both paths converge at rEFInd.
The remainder of the runtime boot sequence should therefore not depend on
which of these two paths was used.

## 4. rEFInd phase
At this stage:
```bash
LUKS             LOCKED
Btrfs            UNAVAILABLE
snapshots        UNAVAILABLE
normal root      UNAVAILABLE
initramfs        NOT RUNNING
```
rEFInd selects and launches the appropriate UKI.
The UKI is stored on the EFI System Partition and can therefore be loaded
without unlocking the LUKS container.
rEFInd must not require access to the encrypted root filesystem.

## 5. UKI phase
The UKI contains the components required to enter Linux early userspace.
Conceptually:
	UKI
	|
	+-- Linux kernel
	+-- initramfs
	+-- kernel command line
	+-- metadata
	+-- PCR signature information
	`-- Secure Boot signature
Execution transfers from EFI to the Linux kernel.
At this point the UKI contents participate in the measured boot process
according to the configured measurement policy.

The selected artifact is named `<entry-token>-<kernel-version>.efi`. rEFInd
uses the newest version-aware filename as its main entry and retains older
kernels as submenus. The embedded `.uname` must match both that filename and
the module tree later required for snapshot boot.

The embedded command line selects the normal Btrfs root and LUKS mapping.
Snapshot selection does not replace the running UKI; dracut adds only the
runtime overlay fragment after a compatible snapshot is selected.

## 6. Kernel initialization
The Linux kernel:
1. initializes the architecture;
2. initializes memory;
3. initializes required drivers;
4. initializes the initramfs;
5. starts /init.
The initramfs was generated by dracut.
Control now moves from firmware/EFI boot into Linux early userspace.

## 7. dracut early userspace
At initramfs entry:
```bash
kernel            RUNNING
initramfs         AVAILABLE
/run              AVAILABLE
real root         NOT MOUNTED
LUKS              LOCKED
Btrfs root        UNAVAILABLE
```
dracut parses the kernel command line and initializes the devices required
to locate the root filesystem.
The custom snapshot-menu module participates in this phase.

## 8. Snapshot trigger phase
Snapshot selection must be requested before the normal LUKS password input
phase can consume keyboard input.
The `systemd-cryptsetup@.service` drop-in starts
`snapshot-key-listener-stop` as an `ExecStartPre` operation. That controller
starts the C input listener for the configured trigger window (currently
`ALT+B` for 5.0 seconds), stops it, restores the display/input state and then
returns control to cryptsetup.
Conceptually:
              listener
                 |
           keyboard input
                 |
          trigger detected?
             /       \
           no         yes
           |           |
           |           v
           |    create request marker
           |           |
           +-----+-----+
                 |
                 v
              continue

The request marker is:
```bash
/run/snapshot-menu-requested
```
The marker represents intent only.
At this stage the snapshots themselves cannot yet be inspected because the
Btrfs filesystem remains inside the locked LUKS container.

## 9. Input ownership transition
This phase is particularly important.
The snapshot listener must stop consuming keyboard input before LUKS
password handling takes ownership of the input device.
Required transition:
	snapshot listener
	       |
	       | stop
	       v
	consume/clean only input belonging
	to the snapshot trigger mechanism
	       |
	       v
	release input device
	       |
	       v
	cryptsetup / systemd ask-password

The listener must not consume input intended for the LUKS password prompt.
Conversely, input used to activate the snapshot menu must not leak into the
password prompt.
Input-device ownership therefore has a strict lifetime.

## 10. LUKS unlock
The encrypted root device is unlocked.
The preferred path is TPM2 automatic unlocking.
Conceptually:
                LUKS
                 |
              TPM token
                 |
                 v
            TPM policy
                 |
          PCRs acceptable?
            /         \
          yes          no
           |            |
           v            v
      automatic      fallback
        unlock       authentication
           |            |
           +-----+------+
                 |
                 v
         /dev/mapper/root

A TPM policy mismatch must not silently bypass LUKS security.
Fallback behavior is determined by the configured LUKS/systemd policy.

The enrolled token evaluates literal PCR 7/14/15 constraints together with a
signed PCR 11 policy authorized by the UKI PCR public key. The kernel command
line requests `tpm2-device=<configured-device>`, PCR measurement and PIN
support. `tpm2-pin=yes` is intentionally always embedded, but a PIN is needed
only when the selected token was enrolled with `TPM_USE_PIN=true`.

Failure to satisfy this policy falls back to normal LUKS authentication; it
does not authorize an unencrypted root. Password and recovery access are kept
when adding or deliberately replacing TPM2 tokens.

## 11. Btrfs becomes available
After successful LUKS unlocking:
	/dev/mapper/root
	        |
	        v
	      Btrfs

At this point the initramfs can inspect:
Btrfs subvolumes;
- Snapper snapshot hierarchy;
- selected snapshot metadata;
- files contained in snapshots;
- kernel information required by the snapshot menu.
The final root filesystem has not yet been mounted.
This is the window in which snapshot discovery and selection occur.

### 11.1 Snapshot-menu decision
The module checks:
```bash
/run/snapshot-menu-requested
```
If the marker does not exist:
```text 
continue normal boot
```
If the marker exists:
```text
execute snapshot-menu
```
Conceptually:
         marker?
         /    \
       no      yes
       |        |
       |        v
       |    mount/access
       |    Btrfs metadata
       |        |
       |        v
       |    discover Snapper
       |      snapshots
       |        |
       |        v
       |     show menu
       |        |
       |        v
       |      select
       |        |
       +----+---+
            |
            v
      root configuration

Failure to request the menu must never alter the normal boot path.

### 11.2 Snapshot discovery
Snapshot discovery reads the configured Snapper snapshot hierarchy.
For every relevant snapshot the menu may determine:
- snapshot number;
- snapshot description;
- creation time;
- snapshot type;
- whether the expected kernel is available;
- other configured metadata.
Expensive metadata should be obtained lazily where possible.
The menu supports pagination according to repository configuration.
Snapshot discovery must not modify snapshots.

### 11.3 Snapshot selection
The user navigates the snapshot list and selects a root snapshot.
The menu must also provide a safe way to cancel and return to the normal
boot path.
Special input such as:
```text
Ctrl-C
escape sequences
EOF
invalid input
```
must result in explicitly defined behavior rather than leaving the
initramfs in a partially configured state.
If PIN protection is enabled, authorization occurs before accepting the
snapshot for boot.

Before PIN authorization, the menu verifies that the selected snapshot
contains `/usr/lib/modules/$(uname -r)`. A missing module tree makes that
entry non-bootable because the running kernel was already selected by the
UKI and cannot be replaced at this stage. The current-system entry bypasses
both this snapshot check and the snapshot PIN.

The configured PIN is checked against a salted SHA-256 value included in the
initramfs. It gates menu selection only and must not be described as disk
encryption or protection against offline inspection.

### 11.4 Normal root path
Without a selected snapshot, dracut proceeds using the configured normal
root subvolume.
Conceptually:
	/dev/mapper/root
	        |
	        v
	   Btrfs filesystem
	        |
	        v
	   normal root subvolume
	        |
	        v
	     real root

Snapshot-specific overlay configuration must not remain active in this
path.
In particular, runtime configuration introduced solely for snapshot boot
must not contaminate normal boot.

### 11.5 Snapshot root path
When a snapshot is selected, the root selection is changed before dracut
performs the final root mount.
Conceptually:
	/dev/mapper/root
	        |
	        v
	  selected snapshot
	        |
	        v
	      lowerdir
	        |
	        v
	     OverlayFS
	   /           \
	lower         upper/work
	   \           /
	    +---------+
	         |
	         v
	      new root

The selected Btrfs snapshot remains the historical base.
Writes generated by the running system must not modify the snapshot.

### 11.6 Kernel command-line handling
The default kernel command line originates from the UKI.
The snapshot module may alter the effective root configuration used by
dracut for the current boot.
The module must preserve unrelated root flags.
For example, given configuration conceptually equivalent to:
```text
rootflags=ssd,discard=async,noatime,compress=zstd:1,...
```
snapshot boot must change only parameters required to select the snapshot
and enable the overlay mechanism.
Normal boot must not retain snapshot-specific parameters.
Kernel-command-line transformation logic should be implemented separately
from the code that applies the transformation so it can be tested without
booting a system.

### 11.7 Overlay phase
For snapshot boot, the dracut overlay mechanism creates the writable root
view.
The selected snapshot is the immutable historical base.
Conceptually:

               /
               |
           OverlayFS
           /       \
          /         \
  Btrfs snapshot   writable layer

The exact implementation is provided by the configured dracut overlay
mechanism.
The custom snapshot module is responsible for selecting/configuring the
correct lower root, not for independently reimplementing OverlayFS unless
explicitly required.

### 11.8 Final root mount
At this point one of two root configurations exists:
	NORMAL BOOT

	/dev/mapper/root
	      |
	      v
	normal Btrfs root
	      |
	      v
	   /sysroot


	SNAPSHOT BOOT

	/dev/mapper/root
	      |
	      v
	selected snapshot
	      |
	      v
	   OverlayFS
	      |
	      v
	   /sysroot

dracut completes the root preparation.

### 11.9 switch_root
After the real root is ready:
	initramfs
	   |
	   v
	switch_root
	   |
	   v
	real root
	   |
	   v
	systemd

The initramfs environment is abandoned.
Temporary resources owned exclusively by the snapshot-menu module must have
been cleaned up or intentionally transferred before this point.

## 12. Runtime state summary
The following table describes the expected availability of important
resources.

| Phase            | LUKS      | Btrfs | Snapshots | Listener | Menu     | Real root |
| ---------------- | --------- | ----- | --------- | -------- | -------- | --------- |
| UEFI             | locked    | no    | no        | no       | no       | no        |
| shim/rEFInd      | locked    | no    | no        | no       | no       | no        |
| kernel           | locked    | no    | no        | no       | no       | no        |
| early dracut     | locked    | no    | no        | yes      | no       | no        |
| LUKS unlock      | unlocking | no    | no        | stopped  | no       | no        |
| post-unlock      | open      | yes   | yes       | no       | possible | no        |
| snapshot menu    | open      | yes   | yes       | no       | yes      | no        |
| root preparation | open      | yes   | yes       | no       | no       | preparing |
| switch_root      | open      | yes   | yes       | no       | no       | yes       |

This table should be consulted before moving code between dracut hooks.

## 13. Critical ordering constraints
The following ordering is intentional:

	snapshot trigger
	      BEFORE
	LUKS password input

	LUKS unlock
	      BEFORE
	snapshot discovery

	snapshot selection
	      BEFORE
	final root mount

	snapshot root configuration
	      BEFORE
	OverlayFS/root preparation

	cleanup
	      BEFORE
	switch_root
Changing these relationships is an architectural change, not a local
refactoring.

## 14. Failure paths
Every early-boot component must have an explicitly defined failure policy.
Failures that affect only optional snapshot functionality should prefer a
safe return to normal boot when doing so does not violate security or leave
partial state.
Failures involving:
LUKS integrity;
Secure Boot trust;
TPM policy configuration;
ambiguous root selection;
corrupted root configuration;
must not be hidden merely to continue booting.
The exact failure policy for each component is documented in `docs/invariants.md`

## 15. Boot-flow validation
Changes affecting this flow must be evaluated against at least:
- Normal boot
- TPM automatic unlock
- LUKS fallback authentication
- snapshot trigger not requested
- snapshot trigger requested
- snapshot menu cancelled
- valid snapshot selected
- invalid/unbootable snapshot
- listener timeout
- snapshot PIN enabled
- snapshot PIN disabled
Static validation does not prove that these scenarios boot successfully.
Tests should validate state transitions, generated configuration and
decision logic wherever real boot execution is unavailable
