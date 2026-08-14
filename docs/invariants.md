# System Invariants

## 1. Purpose

This document defines properties that must remain true across repository
changes.

These invariants have higher priority than implementation preferences,
refactoring goals or style improvements.

A change that violates an invariant is an architectural or security change
and must not be introduced accidentally.

When an invariant must intentionally change, the modification must:

1. be explicitly requested or justified;
2. identify the affected boot/security behavior;
3. update this document;
4. update related architecture and boot-flow documentation;
5. include appropriate validation.

---

## 2. General invariants

The existing working behavior of the system is authoritative unless a task
explicitly requires a behavioral change.

Changes must preserve:

- system bootability;
- data integrity;
- encryption integrity;
- Secure Boot integrity;
- TPM unlock behavior;
- recovery access;
- snapshot rollback capability;
- normal boot when snapshot boot is not requested.

Do not perform unrelated architectural changes while fixing a localized
problem.

Prefer the smallest coherent modification that satisfies the task.

---

## 3. Storage invariants

### 3.1 LUKS boundary

The persistent Linux filesystem must remain inside the configured LUKS
container.

The EFI System Partition is outside the encrypted container because firmware
must access EFI executables before LUKS unlock.

The installer must never silently move sensitive persistent data outside the
encrypted filesystem.

### 3.2 Existing encrypted data

Existing encrypted data must never be destroyed as a side effect of:

- validation;
- configuration inspection;
- test execution;
- repository refactoring.

Commands that can destroy or reinitialize encrypted storage must not be run
during normal development validation.

Examples include:

    cryptsetup luksFormat
    cryptsetup luksKillSlot
    wipefs
    mkfs.*
    destructive partitioning commands
    dd against block devices

### 3.3 Device identity

Scripts must not assume that a device keeps the same `/dev/sdX`,
`/dev/nvmeXnY` or mapper name across systems unless that identity is explicitly
part of configuration.

When persistent identity is required, prefer stable identifiers such as:

- UUID;
- PARTUUID;
- configured mapper names.

The LUKS UUID written to the target `crypttab` must be read from the completed
LUKS container after in-place encryption. A UUID read from the plaintext
Btrfs filesystem before encryption is not a valid LUKS identity.

### 3.4 Target configuration boundary

Storage setup runs from a live environment. Persistent `fstab` and `crypttab`
changes must therefore target the mounted installation root, not the live
environment's `/etc`.

The destructive Btrfs/LUKS storage phase must execute exactly once. Entering
the target chroot must not repeat subvolume creation or in-place encryption.

---

## 4. Btrfs invariants

The configured Btrfs root layout must remain internally consistent.

When existing directories are moved into dedicated data subvolumes, both
visible and hidden entries must be preserved. Mounting the new subvolume must
not make dotfiles from the installed system disappear.

Subvolume paths used by:

- installer scripts;
- `/etc/fstab`;
- kernel command line;
- dracut;
- Snapper;
- snapshot-menu;
- snapshot boot logic;

must refer to the same logical layout.

A subvolume path must not be changed in one component without checking all
other consumers.

### 4.1 Normal root

Normal boot must use the configured normal root subvolume.

Snapshot-specific configuration must not alter normal boot when no snapshot
has been selected.

### 4.2 Snapshot integrity

A historical Snapper snapshot selected for boot must not be modified by the
running system.

Snapshot boot must preserve the snapshot as the historical lower state.

Writes performed during snapshot boot must target the configured writable
overlay or equivalent writable layer.

### 4.3 Snapshot deletion

Repository validation must never delete snapshots.

Snapshot deletion must not be introduced as an implicit side effect of:

- kernel cleanup;
- UKI cleanup;
- validation;
- snapshot discovery;
- boot-menu generation.

---

## 5. LUKS invariants

LUKS remains the primary data-at-rest protection mechanism.

TPM support supplements LUKS and does not replace it.

### 5.1 Recovery access

The system must retain a recovery path that does not depend exclusively on
successful TPM automatic unlock.

Changes to TPM enrollment must not intentionally eliminate all non-TPM
recovery mechanisms unless explicitly requested.

### 5.2 Secrets

The following must never be written to normal logs:

- LUKS passphrases;
- LUKS recovery keys;
- TPM PINs;
- plaintext secrets;
- Secure Boot private keys;
- PCR signing private keys.

Secrets must not be passed through command-line arguments when a safer input
mechanism is available.

Temporary files containing secrets must:

- have restrictive permissions;
- have a clearly defined lifetime;
- be removed during cleanup.

### 5.3 Keyslots and tokens

Existing LUKS keyslots and tokens must not be removed merely because new
enrollment is being performed.

A script must not assume that the TPM token is the only token present.

Changes to token parsing must tolerate unrelated LUKS tokens unless the task
explicitly requires otherwise.

---

## 6. TPM invariants

The TPM must never be cleared, reset or reinitialized by repository
validation.

Commands that alter TPM ownership or destroy TPM state must not be executed
automatically.

### 6.1 PCR policy

The configured PCR policy is security-sensitive and compatibility-sensitive.

Changing:

- PCR numbers;
- PCR banks;
- measured phases;
- expected signatures;
- TPM policy construction;

may invalidate existing LUKS TPM enrollment.

Such changes must therefore be treated as a behavioral and security change.

They must not be introduced as incidental refactoring.

### 6.2 TPM failure

Failure of TPM automatic unlock must not result in bypassing LUKS encryption.

The configured fallback authentication path may be used, but encryption must
remain enforced.

---

## 7. Secure Boot invariants

Secure Boot must not be disabled as a workaround for installation or boot
problems.

Signature verification must not be bypassed merely to make a generated EFI
binary boot.

### 7.1 Firmware trust hierarchy

The installer must distinguish between firmware states.

It must never assume that firmware is in Setup Mode.

It must not automatically:

- clear PK;
- clear KEK;
- clear db;
- clear dbx;
- enter Setup Mode;
- replace the firmware trust hierarchy.

Existing vendor keys must be preserved unless the installation mode
explicitly requires and authorizes replacement.

### 7.2 Direct trust mode

When firmware Setup Mode is available and the selected installation policy
uses direct enrollment, repository-managed Secure Boot keys may be enrolled
according to the configured procedure.

The resulting boot chain must remain trusted from firmware through rEFInd and
the UKI.

### 7.3 shim/MOK mode

When the existing firmware trust hierarchy must be preserved, the configured
shim/MOK path must be used.

Conceptually:

    UEFI firmware
          |
         shim
          |
         MOK
          |
        rEFInd
          |
         UKI

The installer must not silently fall back from shim/MOK trust to unsigned
execution.

### 7.4 Signing keys

Private signing keys must never be committed to the repository.

Tests and fixtures must use obviously fake material where key-like content is
required.

### 7.5 Enrollment and loader identity

When direct firmware enrollment is authorized, the hierarchy must be written
in `db`, `KEK`, `PK` order. `PK` must be enrolled last because that transition
exits Setup Mode. Validation must never exercise this sequence against real
EFI variables.

Signature verification must target the repository-signed executable in the
selected chain:

- direct trust verifies `refind_x64.efi` with the repository db certificate;
- shim/MOK trust verifies the rEFInd payload installed as `grubx64.efi` with
  the repository db certificate;
- vendor-signed shim and MokManager are verified as signed PE artifacts, not
  incorrectly assumed to carry the repository db signature.

Boot-chain packages obtained from a pinned Snapshot repository must retain
archive-keyring authentication. Missing archive keys are a fatal error;
`trusted=yes` is forbidden.

The persisted `/etc/securebootmode.conf` value represents the trust path
selected at installation time. It must not be treated as proof that the live
firmware is still in Setup Mode after `PK` enrollment.

---

## 8. UKI invariants

The UKI represents the boot artifact consumed by rEFInd.

Generation of a new UKI must preserve the expected composition, including
components required by the configured boot architecture.

Depending on system configuration this may include:

- Linux kernel;
- initramfs;
- embedded kernel command line;
- metadata;
- PCR signature data;
- Secure Boot signature.

A UKI that fails required signature or structural validation must not be
treated as valid merely because the file exists.

When multiple kernels are requested, any failed kernel makes the overall
operation fail after the complete report is printed. An older artifact at the
expected path must not turn a failed `kernel-install add` into success.
An artifact that fails mandatory validation must be removed from the ESP and
the generated rEFInd menu refreshed so it cannot become the default entry.

UKIs must retain the path contract
`/boot/efi/EFI/Linux/<entry-token>-<kernel-version>.efi`. The rEFInd menu,
kernel removal and validators depend on it. Menu replacement must be atomic
and kernel versions must use version-aware rather than lexical ordering.

PCR and Secure Boot private keys must retain restrictive permissions, must
not be regenerated when persistent keys already exist and must never appear
in logs or fixtures.

### 8.1 Kernel command line

Changes to the embedded or runtime kernel command line must preserve unrelated
boot options.

Snapshot boot logic must change only the parameters necessary for snapshot
root selection and overlay behavior.

Normal boot must not retain snapshot-only parameters.

`/etc/kernel/cmdline` is the authoritative normal-boot cmdline embedded by
ukify. Dracut host-only cmdline embedding must remain disabled unless ownership
and duplication of all embedded options are re-evaluated.

---

## 9. rEFInd invariants

rEFInd remains the selected boot manager unless an explicit task changes the
boot architecture.

Do not replace rEFInd with another boot manager as part of unrelated work.

The configured EFI paths and generated menu entries must remain consistent
with UKI generation.

Changes to naming conventions or EFI directory layout must consider:

- rEFInd discovery;
- manual stanzas;
- submenu generation;
- icons;
- kernel cleanup;
- UKI removal.

---

## 10. dracut invariants

The custom snapshot-menu functionality runs in early userspace and is
therefore boot-critical.

Changes must preserve the relative ordering described in
`docs/boot-flow.md`.

The following sequence must remain logically true:

    snapshot trigger
          BEFORE
    LUKS password input
    
    LUKS unlock
          BEFORE
    snapshot discovery
    
    snapshot selection
          BEFORE
    final root mount
    
    root selection
          BEFORE
    switch_root

Moving logic across these boundaries is an architectural change.

### 10.1 Normal boot

The dracut snapshot module must remain optional.

If snapshot boot is not requested, the module must allow normal boot to
continue without snapshot-specific state.

### 10.2 Failure cleanup

Temporary mounts, file descriptors, listeners and marker state created by the
module must have a defined cleanup path.

A cancelled or failed snapshot-menu execution must not leave dracut in a
partially modified root configuration.

---

## 11. Snapshot trigger and input invariants

The snapshot trigger operates before LUKS password handling.

Keyboard input ownership must therefore be explicitly controlled.

### 11.1 Listener lifetime

The snapshot key listener must terminate or release input ownership before
the LUKS password prompt begins consuming user input.

The listener must not consume characters intended for:

- cryptsetup;
- systemd-ask-password;
- the snapshot PIN prompt;
- subsequent console input.

### 11.2 Input leakage

Input used to activate the snapshot menu must not leak into the following
password prompt.

Conversely, cleanup logic must not consume input that belongs to the LUKS
authentication stage.

### 11.3 Trigger semantics

Failure to detect the snapshot trigger must result in normal boot.

The absence of a trigger marker is not an error condition.

---

## 12. Snapshot-menu invariants

Snapshot discovery must be read-only.

Displaying a snapshot in the menu must not modify it.

Metadata inspection should not mount or modify more state than necessary.

The menu must have explicitly defined behavior for:

- cancellation;
- Ctrl-C;
- EOF;
- invalid key sequences;
- no snapshots;
- unavailable snapshot kernel;
- timeout;
- PIN failure when PIN protection is enabled.

A snapshot whose `/usr/lib/modules` tree does not contain the kernel already
running from the UKI must never be accepted for boot. Reporting it as
unavailable in the menu is not sufficient if selection can still continue.

The current-system entry must remain selectable without a snapshot PIN. The
salted PIN hash stored in the initramfs is a menu access control, not a
cryptographic boundary and not a substitute for LUKS authentication.

The menu must not leave the terminal/input device in an unusable state when
exiting.

---

## 13. Overlay boot invariants

Snapshot boot must preserve the selected snapshot as the lower historical
state.

The writable layer must be distinct from the snapshot itself.

Normal boot must not enable the snapshot overlay solely because a previous
snapshot boot occurred.

Runtime files used to request snapshot boot must not persist across reboot
unless explicitly designed to do so.

---

## 14. Configuration invariants

Values shared by multiple scripts should have one authoritative source where
practical.

Examples include:

- root subvolume;
- snapshot directory;
- ESP mount point;
- UKI path;
- Secure Boot key paths;
- PCR policy;
- listener trigger;
- trigger timeout;
- snapshot pagination;
- PIN settings.

Configuration parsing must reject invalid values rather than silently
inventing unsafe defaults.

Security-sensitive defaults should be conservative.

---

## 15. Common framework invariants

Reusable infrastructure belongs in the repository common framework.

The framework may provide:

- logging;
- error reporting;
- command execution;
- cleanup;
- configuration access;
- input helpers;
- temporary-file management;
- validation helpers.

Domain logic must not become hidden inside generic logging or execution
wrappers.

The top-level `lib/` directory is reserved for cross-cutting infrastructure
used by unrelated features. Domain helpers must remain in the individual
script that owns the behavior. A feature-level common file is permitted only
for functions genuinely consumed by multiple scripts; testability or file
length alone is not sufficient justification for creating one.

Common libraries must not depend on high-level installation stages.

Dependency direction must remain:

    installer / feature scripts
              |
              v
        domain helpers
              |
              v
        common framework

Circular sourcing relationships must not be introduced.

Production functions in new or modified Bash code must use the
`<owner>.<function>` namespace. The owner must identify the file or framework
module that defines the function. Callers must not rely on unqualified aliases
or redefine another owner's namespace.

Logs and final summaries may contain resolved device paths, mapper names,
subvolume paths, mount points and non-secret configuration. They must never
contain passphrases, PINs, recovery keys or private-key material.

---

## 16. Validation invariants

Normal automated validation must be non-destructive.

Validation must not:

- repartition disks;
- format filesystems;
- modify real LUKS containers;
- enroll TPM keys;
- clear TPM state;
- enroll or remove firmware Secure Boot keys;
- modify EFI variables;
- reboot;
- shut down;
- remove snapshots;
- write to real block devices.

A test must not require root merely because production code normally runs as
root if the relevant logic can instead be tested using fixtures or mocks.

---

## 17. Existing behavior and refactoring

Existing working behavior must be preserved unless the task explicitly
changes it.

Best practices are not, by themselves, sufficient justification for changing
observable boot behavior.

When refactoring existing code:

1. characterize current behavior;
2. add or identify validation covering that behavior;
3. make the smallest refactoring;
4. rerun validation;
5. separate behavior changes from structural cleanup where practical.

Refactoring and functional changes should not be mixed unnecessarily.

---

## 18. Failure philosophy

Failures must not be hidden when continuing would compromise:

- encryption;
- boot trust;
- root selection;
- filesystem integrity;
- TPM policy integrity.

Optional functionality may fail back to normal boot only when that fallback
is explicitly safe.

For example:

    snapshot menu unavailable
            |
            v
    normal root still unambiguously valid
            |
            v
    normal boot may continue

but:

    Secure Boot trust cannot be established
            |
            v
    do not silently boot unsigned code

---

## 19. Documentation consistency

Changes affecting architectural behavior must update relevant documentation.

Use:

- `docs/architecture.md` for component relationships;
- `docs/boot-flow.md` for runtime ordering;
- `docs/invariants.md` for non-negotiable properties;
- `docs/tests.md` for validation strategy.

Documentation drift should be treated as a defect.
