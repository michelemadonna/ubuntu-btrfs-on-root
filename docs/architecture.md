# System Architecture

## 1. Purpose

This repository automates the installation and configuration of an Ubuntu
system with:

- Btrfs root filesystem
- LUKS full-disk encryption
- Secure Boot
- Unified Kernel Images (UKI)
- TPM2-based automatic LUKS unlock
- Snapper snapshots
- rEFInd boot manager
- custom dracut snapshot-selection module
- snapshot boot through an overlay filesystem

The repository is primarily implemented in Bash.

The system is designed so that the normal boot path remains simple while
allowing an alternative root snapshot to be selected during early boot.

---

## 2. High-level architecture

The system is composed of the following layers:

    Firmware / UEFI
          |
          v
    Secure Boot
          |
          v
        rEFInd
          |
          v
          UKI
      +---------+
      | kernel  |
      | initrd  |
      | cmdline |
      | PCR sig |
      +---------+
          |
          v
        dracut
          |
          +----------------------+
          |                      |
          v                      v
    TPM / LUKS unlock      snapshot-menu module
          |                      |
          +-----------+----------+
                      |
                      v
                 Btrfs root
                      |
              +-------+-------+
              |               |
              v               v
          normal root      snapshot root
                              |
                              v
                         overlay root
                              |
                              v
                         userspace

## 3. Storage architecture
### 3.1 Encryption
The Linux filesystem resides inside a LUKS container.
Conceptually:

	physical disk
	    |
	    +-- EFI System Partition
	    |
	    +-- LUKS container
	            |
	            v
	        /dev/mapper/root
	            |
	            v
	          Btrfs

The EFI System Partition is intentionally outside the LUKS container because
UEFI firmware and rEFInd must be able to read EFI executables before the
encrypted volume is unlocked.

## 4. Btrfs layout
The Btrfs filesystem contains the operating-system root and additional
subvolumes.
Example logical layout:
	Btrfs filesystem
	|
	+-- @ubuntu   
		|
		+-- @home
		|
		+-- @log
		|
		+-- @cache
		|
		+-- @temp
		|
		+-- @libvirt
		|
		+-- @swap
		|
		`-- .snapshots
		     |
		     +-- 1/snapshot
		     +-- 2/snapshot
		     `-- ...
The exact layout is defined by repository configuration and installation
scripts.
Scripts must not assume a subvolume path independently from the central
configuration.

## 5. Snapshot architecture
Snapper manages snapshots of the root filesystem.
Snapshots are stored below the configured snapshot hierarchy.
A snapshot is not normally mounted directly as the final root filesystem.
For snapshot boot, the selected snapshot is treated as a read-only lower
layer and a writable overlay is created above it.
Conceptually:
selected Btrfs snapshot
        |
        v
    lowerdir
        |
        +---------+
                  |
             OverlayFS
                  |
          +-------+-------+
          |               |
      lowerdir         upper/work
          |               |
          +-------+-------+
                  |
                  v
                 /


This prevents accidental modification of the historical snapshot during
boot.

---

## 6. Boot architecture

The system supports two Secure Boot trust paths depending on firmware
configuration and Secure Boot key enrollment state.

### 6.1 Direct Secure Boot path

When the firmware is in Setup Mode and the repository-managed Secure Boot
keys can be enrolled into the firmware trust database, rEFInd is trusted
directly by the firmware.

    UEFI firmware
          |
          | firmware db
          v
        rEFInd
          |
          v
          UKI
          |
          v
     Linux kernel

In this configuration:

- repository-managed Secure Boot keys are enrolled into the firmware;
- rEFInd is signed with the corresponding Secure Boot key;
- UKIs are signed with a key accepted by the resulting trust chain;
- shim is not required as an intermediate trust component.

This is the preferred direct trust path when firmware key enrollment is
available and explicitly selected by the installation process.


### 6.2 shim-based Secure Boot path

When Secure Boot is enabled but the firmware is not in Setup Mode and the
existing platform Secure Boot keys must be preserved, the installer must
not assume that repository-managed keys can be enrolled directly into the
firmware trust database.

The boot chain uses shim as an intermediate trust component.

Conceptually:

    UEFI firmware
          |
          | vendor / Microsoft trust
          v
         shim
          |
          | MOK trust
          v
        rEFInd
          |
          v
          UKI
          |
          v
     Linux kernel

shim must itself be signed by a certificate already trusted by the firmware.

Repository-controlled trust is introduced through the Machine Owner Key
(MOK) mechanism rather than by replacing the firmware Secure Boot
hierarchy.

The installer must not clear or replace existing PK, KEK or db variables
merely to install the repository-managed key.


### 6.3 Boot path selection

The installation process determines the appropriate Secure Boot path from
the firmware state.

Conceptually:

                         Secure Boot
                              |
                              v
                       firmware state
                              |
                    +---------+---------+
                    |                   |
                    v                   v
               Setup Mode          User Mode /
                    |              existing keys
                    |                   |
                    v                   v
             enroll own keys          shim
                    |                   |
                    v                   v
                 rEFInd              MOK trust
                    |                   |
                    |                   v
                    |                rEFInd
                    |                   |
                    +---------+---------+
                              |
                              v
                             UKI
                              |
                              v
                         Linux kernel

The exact detection and installation procedure belongs to the installation
logic rather than to this architecture document.

The installer records the trust path selected from the initial firmware
`SetupMode` in `/etc/securebootmode.conf`. This is an installation-mode
decision, not a continuously refreshed report of the current firmware bit:
enrolling `PK` necessarily exits Setup Mode while the installed system remains
on the direct trust path.

## 7. Unified Kernel Image

Each UKI contains the components required for early boot.

Conceptually:

    UKI
    |
    +-- EFI stub
    +-- Linux kernel
    +-- initramfs
    +-- kernel command line
    +-- metadata
    +-- PCR signature data
    `-- Secure Boot signature

The UKI is generated using the systemd UKI toolchain.

The EFI executable is signed using the configured Secure Boot key.

The concrete pipeline is Debian kernel postinst/postrm -> `kernel-install
add/remove` -> dracut initrd generation -> ukify assembly and PCR signatures
-> Secure Boot signing -> rEFInd menu regeneration. `/etc/kernel/install.conf`
selects the `uki` layout, dracut and ukify. `/etc/kernel/entry-token` supplies
the artifact prefix, producing
`/boot/efi/EFI/Linux/<entry-token>-<kernel-version>.efi`.

The ukify policy signs PCR 11 phase paths using a persistent RSA key pair
below `/etc/uki/keys`. The complete UKI is signed with the sbctl db key;
`SignKernel=false` means the embedded kernel is not separately signed by this
policy.

The kernel command line embedded in the UKI represents the default boot path.
Snapshot boot may modify selected runtime parameters during initramfs
processing.

The normal command line comes from `/etc/kernel/cmdline`; dracut host-only
cmdline embedding is disabled so ukify remains its single owner. It identifies
the Btrfs UUID, normal root subvolume, LUKS UUID and failure policy.

The rEFInd hook groups UKIs by entry token, sorts versions newest-first with
version-aware ordering, uses the newest UKI as the main entry and exposes
older UKIs as submenus. Replacement is atomic; an empty generated file remains
when the final UKI is removed.

---

## 8. Secure Boot architecture

Secure Boot establishes authenticity and integrity of the pre-boot
execution chain.

The project supports two trust models.

### 8.1 Firmware-enrolled trust

When custom key enrollment is available:

    UEFI
      |
      | PK / KEK / db
      v
    rEFInd
      |
      v
     UKI
      |
      v
    Linux

The repository-managed signing certificate is ultimately anchored in the
firmware Secure Boot trust database.


### 8.2 shim/MOK trust

When existing firmware keys are retained:

    UEFI
      |
      | firmware db
      v
     shim
      |
      | MOK
      v
    rEFInd
      |
      v
     UKI
      |
      v
    Linux

The firmware trusts shim through the existing Secure Boot trust database.

shim extends the trust chain using the Machine Owner Key mechanism,
allowing repository-managed EFI components to participate in Secure Boot
without replacing the existing firmware key hierarchy.


### 8.3 Trust responsibilities

The architecture distinguishes:

    Firmware trust
        PK / KEK / db
              |
              v
        EFI executable trust
              |
         +----+----+
         |         |
      direct      shim
         |         |
         |        MOK
         |         |
         +----+----+
              |
              v
            rEFInd
              |
              v
             UKI

Changes to any of the following are security-sensitive:

- PK
- KEK
- db
- dbx
- shim
- MOK
- rEFInd signing
- UKI signing
- signing private keys

The installer must preserve the existing firmware trust hierarchy unless
the selected installation mode explicitly requires and permits its
modification.

The implementation uses isolated phase entry points:

    secure-boot-setup
          |
          +-- sbctl-setup
          |     create or reuse PK / KEK / db
          |     direct enrollment order: db -> KEK -> PK
          |
          +-- shim-setup        (shim/MOK path only)
          |     prepare vendor-signed shim and MokManager
          |     request db certificate enrollment as MOK
          |
          +-- refind-setup
          |     direct: sign refind_x64.efi
          |     shim: sign grubx64.efi behind shim
          |
          `-- fwupd-setup
                configure the matching trust path
                sign and verify the fwupd EFI companion

Each phase remains in its owning script and is executed as a subprocess.
Exported configuration carries the selected trust path and key locations
across phase boundaries.

Pinned Debian Snapshot fallbacks are accepted only when package metadata is
authenticated with the Debian archive keyring. HTTPS transport alone is not
a substitute for package signature verification.

## 9. TPM architecture

The TPM is used to release LUKS unlocking material when the measured boot
state matches the configured policy.

Conceptually:

    firmware measurements
            |
            v
           PCRs
            |
            v
      TPM policy evaluation
            |
       +----+----+
       |         |
      match     mismatch
       |         |
       v         v
    unlock    fallback
               authentication

The TPM does not replace LUKS.
The TPM stores or protects sealed key material associated with the LUKS
enrollment.
The selected PCR policy is part of the security architecture and must be
treated as a compatibility-sensitive configuration.

## 10. dracut architecture
The initramfs is generated using dracut.
A custom module provides snapshot-selection functionality.
Example module:
```bash
/usr/lib/dracut/modules.d/92snapshot-menu/
```
The installed module is assembled from
`btrfs-snapshots-mng/dracut/92snapshot-menu`. Its relevant artifacts are:
```text
installed executables:
    /usr/libexec/snapshot-menu
    /usr/libexec/snapshot-key-listener
    /usr/libexec/snapshot-key-listener-stop

configuration:
    /etc/snapshot-menu.conf

hooks:
    pre-mount/00 snapshot-menu-hook.sh

systemd integration:
    systemd-cryptsetup@.service.d/50-snapshot-key-listener-stop.conf
```

The systemd cryptsetup drop-in runs the listener controller as
`ExecStartPre`. It owns the short trigger window, stops the C input listener
and leaves `/run/snapshot-menu-requested` only when `ALT+B` was detected.
The pre-mount hook consumes that marker after `/dev/root` becomes available.

The module must execute after the encrypted root device becomes available
but before the final root filesystem is mounted.
Exact hook ordering is documented separately in boot-flow.md.

## 11. Snapshot menu architecture
The snapshot menu has three logical components.
### Trigger
Detect whether snapshot selection has been requested during early boot.
### Discovery
Discover available Snapper snapshots and metadata.
### Selection
Present a navigable menu and return the selected snapshot.
Conceptually:
	keyboard listener
	        |
	        v
	  request marker
	        |
	        v
	  snapshot discovery
	        |
	        v
	    menu model
	        |
	        v
	   user selection
	        |
	        v
	root configuration

The keyboard listener and UI must not interfere with the LUKS password
prompt.

Input consumed by the snapshot trigger must not leak into later password
input.

The menu always contains the current-system entry. Snapshot entries are
accepted only when their `/usr/lib/modules` tree contains the kernel version
already running from the UKI. A selected snapshot is mounted read-only as the
OverlayFS lower layer; a tmpfs-backed upper layer receives runtime writes.

Optional snapshot PIN protection applies only to snapshot entries. Its salt
and SHA-256 hash are embedded in the initramfs configuration, so it is a UI
authorization measure rather than an encryption or offline-attack boundary.

## 12. Normal boot path

Normal boot must remain possible without using snapshot functionality.

Simplified flow:

    rEFInd
       |
       v
      UKI
       |
       v
     dracut
       |
       v
    LUKS unlock
       |
       v
    configured root subvolume
       |
       v
    switch_root

Snapshot functionality must therefore be optional.
Failure or absence of the snapshot trigger must not prevent normal boot.

## 13. Snapshot boot path
When snapshot boot is requested:
	rEFInd
	   |
	   v
	  UKI
	   |
	   v
	 dracut
	   |
	   v
	LUKS unlock
	   |
	   v
	snapshot menu
	   |
	   v
	selected snapshot
	   |
	   v
	OverlayFS preparation
	   |
	   v
	snapshot-backed root
	   |
	   v
	switch_root


The normal root subvolume remains unchanged.

## 14. Installation architecture

`setup.sh` runs the storage phase once from the live environment, before the
target chroot is prepared:

    setup.sh preflight
           |
           v
    btrfs-root/scripts/btrfs-root-setup
           |
           +-- create the configured Btrfs subvolume layout
           |
           +-- encrypt the root partition in place as LUKS2
           |
           +-- open /dev/mapper/root and grow Btrfs
           |
           +-- write <target>/etc/crypttab and <target>/etc/fstab
           |
           `-- print the completed-operation summary

The storage coordinator delegates privileged execution to the scripts under
`btrfs-root/scripts/`. Each phase script owns its validation, artifact builders
and execution functions. The final summary belongs to the
`btrfs-root-setup` orchestrator. This keeps each phase's control flow visible
in one file.

After storage setup, `setup.sh` prepares the target chroot. Package,
Secure Boot, Snapper/dracut, UKI and TPM-related phases execute inside that
chroot. The destructive Btrfs/LUKS phase must not be repeated there.

Installation scripts should preserve clear phase boundaries.
Reusable functionality belongs in the common library rather than being
duplicated between phases.

## 15. Common framework
Shared Bash functionality resides under:

```bash
./lib/
```
The common framework is responsible for cross-cutting behavior such as:
- logging
- command execution
- error reporting
- cleanup
- validation
- user input
- configuration
- dry-run behavior	

The common module `lib/common.sh` provides logging, summaries, fatal error
handling, privilege checks, and reusable configuration preconditions.
It deliberately does not change shell options, so sourcing it cannot alter a
caller's error-handling semantics.

Feature-specific helpers remain in the script that owns their behavior and may
depend on the common module. A feature-level common file is justified only for
functions genuinely shared by multiple scripts, not as a general separation
layer.

Sourced Bash functions expose their owner in the function name using
`<owner>.<function>`. Examples include `common.require_root`,
`luks-setup.build_crypttab_entry` and `btrfs-root-setup.print_summary`.
Callers always use the qualified name, making cross-file control flow visible
without relocating the implementation.

Domain-specific logic should not be placed in the generic logging or command
execution layers.
Example dependency direction:
installation scripts
        |
        +------> domain helpers
        |
        `------> common framework
The common framework must not depend on individual installer stages.
The top-level framework must also not become a collection of unrelated domain
helpers; keeping feature logic local is required for traceable control flow.

## 16. Configuration architecture
The main configuration file is:

```bash
./setup.conf
``` 
Values that affect multiple components must have a single authoritative
source whenever practical.
Examples include:
- root subvolume
- snapshot directory
- EFI mount point
- UKI destination
- PCR selection
- snapshot-menu timeout
- snapshot-menu pagination
- TPM options
- Secure Boot key locations
Avoid duplicating the same value across unrelated scripts.
Generated configuration should be derived from repository configuration
rather than manually synchronized.

## 17. Trust boundaries
The architecture contains several important trust boundaries.
### Firmware boundary
UEFI and Secure Boot establish trust in EFI binaries.
### Initramfs boundary
The initramfs executes privileged code before the normal root filesystem is
available.
All code included in the initramfs must therefore be treated as
security-sensitive.
### LUKS boundary
The encrypted filesystem separates persistent private data from the
unencrypted boot environment.
### TPM boundary
The TPM controls access to sealed material according to the configured PCR
policy.
### Snapshot boundary
Snapshots represent historical filesystem state and must not be silently
modified during snapshot boot.

## 18. External commands
The system relies on several external tools.
Core examples:
```bash
refind-install
apt
btrfs
cryptsetup
systemd-cryptenroll
tpm2-tools
snapper
dracut
ukify
sbctl
findmnt
lsblk
blkid
mount
umount
openssl
```
Direct interaction with these tools should be isolated where practical.
Parsing and decision logic should remain separate from command execution to
allow validation without privileged operations.

## 19. Validation architecture
Testing is divided into multiple levels.
### Static
```bash
bash -n
shellcheck
shfmt
```
### Logic
Pure or mostly pure Bash functions are tested using fixtures and mocks.
Examples:
- snapshot parsing
- kernel selection
- argument generation
- mount-option generation
- PCR configuration parsing
- configuration validation
### Artifact validation
Generated artifacts may be inspected without applying them:
- initramfs file contents
- UKI metadata
- EFI paths
- generated configuration
- rEFInd entries
- kernel command lines
### Integration
Operations requiring real block devices, Secure Boot firmware state, TPM
state or reboot are outside normal automated validation.
Such testing must use a dedicated disposable environment.

### 20. Architectural dependency rule
Higher-level installation logic may depend on lower-level libraries.
Lower-level libraries must not depend on installation orchestration.
Preferred direction:
	installer
	   |
	   v
	feature modules
	   |
	   v
	domain helpers
	   |
	   v
	common framework

Avoid:
	common.sh
	   |
	   v
	install-ubuntu.sh

Circular dependencies between sourced Bash files should not be introduced.

# 21. Architectural documentation
Detailed operational sequences belong in:
`docs/boot-flow.md`

Non-negotiable properties belong in:
`docs/invariants.md`

Testing strategy belongs in:
`docs/testing.md`

Agent behavior belongs in:
`/AGENTS.md`

This document should describe architecture rather than implementation
instructions for AI agents.
