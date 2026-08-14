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

The kernel command line embedded in the UKI represents the default boot path.
Snapshot boot may modify selected runtime parameters during initramfs
processing.

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
Typical components include:
module-setup.sh
```bash
installed executables:
    /usr/libexec/snapshot-menu
    /usr/libexec/snapshot-key-listener

configuration:
    /etc/snapshot-menu.conf

hooks:
    initqueue / pre-mount / related early-boot hooks
```

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

The installer is divided logically into phases.

Example:

    preflight (inside ./ubuntu-btrfs-root file executed from live environment)
       |
       v
	subvolume creation  (inside ./btrfs-root-setup/scripts/btrfs-subvol-setup script)
       |
       v
    LUKS configuration (inside ./btrfs-root-setup/scripts/btrfs-root-setup script)
       |
       v
    Secure Boot configuration & signing + Bootloader installation (inside ./secure-boot-setup/scripts/secure-boot-setup script)
       |
       v
    Snapper configuration + Snapshot Menu dracut module configuration (inside ./btrfs-snapshot-mng/scripts/btrfs-snapshot-mng-setup script)
       |
       v
    UKI generation  (inside ./uki/scripts/install-uki script)
       |
       v
    TPM configuration  (inside ./tpm/scripts/install-tpm script)

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
Domain-specific logic should not be placed in the generic logging or command
execution layers.
Example dependency direction:
installation scripts
        |
        +------> domain helpers
        |
        `------> common framework
The common framework must not depend on individual installer stages.

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
