# Repository Agent Instructions

## Project purpose

This repository installs and configures Ubuntu with:

- Btrfs root filesystem
- LUKS full-disk encryption
- Secure Boot
- UKI boot images
- TPM2 automatic LUKS unlock
- Snapper snapshots
- a custom dracut module for selecting a root snapshot during early boot

The project consists primarily of Bash scripts.

Changes to the boot chain, storage layout, encryption or TPM configuration
must be treated as security-sensitive.

---

## Primary goals

Changes must prioritize, in order:

1. system bootability
2. data integrity
3. encryption integrity
4. Secure Boot integrity
5. TPM sealing integrity
6. rollback capability
7. maintainability
8. user experience

Never trade a higher-priority property for a lower-priority one without
explicit justification.

---

## Existing behavior

This is an existing, working system.

Existing behavior is authoritative unless a task explicitly requests
a behavioral change.

Do not rewrite working code solely to apply preferred patterns or
best practices.

Before modifying existing code:

1. understand its current behavior;
2. identify its callers and dependencies;
3. identify relevant boot/security invariants;
4. preserve existing behavior not explicitly targeted by the task.

Prefer the smallest change that solves the requested problem.

## Refactoring

Refactoring must be incremental.

Do not combine unrelated refactoring with behavioral changes.

When extracting existing logic into the common framework, preserve
observable behavior first. Improvements may be performed separately
after equivalent behavior has been validated.

If existing code conflicts with a documented best practice, do not
silently rewrite it. Report the conflict and determine whether changing
it could affect compatibility or boot behavior.

## Architecture

Read the following documents when relevant:

- `docs/architecture.md`
- `docs/boot-flow.md`
- `docs/invariants.md`
- `docs/testing.md`

Do not duplicate detailed architecture documentation in this file.

---

## Bash requirements

All executable shell scripts must use Bash explicitly.

Prefer:

    #!/usr/bin/env bash

New or modified scripts must:

- pass `bash -n`
- pass ShellCheck
- follow the repository shfmt configuration
- quote parameter expansions unless intentional
- use arrays when representing argument lists
- avoid `eval`
- avoid parsing `ls`
- avoid unnecessary subshells
- avoid temporary files when pipes or variables are sufficient
- use `printf` rather than `echo` when output interpretation matters
- use `local` for function-local variables
- use meaningful function and variable names
- keep functions focused on one responsibility

Do not silence ShellCheck warnings without documenting why.

---

## Error handling

Scripts that perform installation or system modification must fail
predictably.

Use the common framework for:

- logging
- warnings
- fatal errors
- command execution
- temporary files
- cleanup
- user input
- password/PIN input

Do not implement duplicate logging or error-handling frameworks inside
individual scripts.

When appropriate, use:

    set -euo pipefail

Do not add it mechanically to sourced libraries where its behavior could
unexpectedly affect the caller.

Explicitly handle expected command failures rather than relying on
`set -e`.

---

## Common framework

Reusable functionality belongs under `lib/`.

Before adding a helper function, search for an existing implementation.

Scripts should source the common framework rather than reimplement:

- logging
- error handling
- command execution
- dry-run support
- cleanup handlers
- configuration parsing
- path validation
- confirmation prompts

Core logic should be separated from destructive execution whenever
practical.

Prefer:

    validate_luks_configuration
    build_cryptenroll_arguments
    enroll_tpm_key

over one large function performing all operations.

This separation is required to make logic testable without modifying a
real system.

---

## Security invariants

Never weaken these properties unless explicitly requested.

### LUKS

- Never remove an existing LUKS keyslot unless explicitly required.
- Never assume the TPM token is the only recovery mechanism.
- Recovery access must remain possible.
- Never expose passphrases, PINs or recovery keys in logs.
- Never pass secrets through command-line arguments when a safer mechanism
  is available.

### Secure Boot

- Do not disable Secure Boot as a workaround.
- Do not bypass signature verification.
- Do not replace signing keys automatically.
- Do not enroll or remove firmware keys during validation.
- UKIs and EFI executables expected to participate in the trusted boot
  chain must remain correctly signed.

### TPM

- Do not change PCR policy without explaining the effect on existing
  enrolled LUKS tokens.
- Treat PCR policy changes as compatibility-breaking security changes.
- Never clear the TPM.
- Never execute TPM enrollment during automated repository validation.

### Btrfs / Snapper

- Never delete snapshots as a side effect of validation.
- Snapshot boot must not modify the selected snapshot.
- Preserve the distinction between normal root boot and snapshot boot.
- Do not change subvolume paths without checking every consumer.

### dracut / initramfs

The snapshot menu executes during early boot.

Changes must preserve:

- availability before root mount
- compatibility with LUKS unlocking
- normal boot when no snapshot is selected
- snapshot boot through the expected overlay mechanism
- console/input availability
- cleanup of temporary mounts and resources

---

## Destructive commands

Repository scripts may legitimately contain destructive commands.

The agent may inspect, create and modify such code, but MUST NOT execute
destructive system operations during development or validation unless the
user explicitly requests execution.

Examples include:

- `cryptsetup luksFormat`
- `cryptsetup luksKillSlot`
- `systemd-cryptenroll`
- `mkfs.*`
- `wipefs`
- destructive `sgdisk` operations
- `dd` targeting block devices
- `sbctl enroll-keys`
- EFI variable modifications
- TPM clear/reset operations
- reboot or shutdown
- writes to real block devices

Do not "test" these commands against the development machine.

---

## Validation strategy

This repository distinguishes:

1. static validation
2. unit validation
3. artifact validation
4. destructive/integration testing

Normal agent work may automatically perform categories 1-3.

Category 4 requires an explicitly prepared disposable environment.

### Static validation

Run:

    bash -n
    shellcheck
    shfmt -d

for modified Bash files.

### Unit validation

Pure functions should be tested independently from the host environment.

Use fixtures and mocks for:

- `lsblk`
- `findmnt`
- `blkid`
- `cryptsetup`
- `systemd-cryptenroll`
- `btrfs`
- `snapper`
- `bootctl`
- `sbctl`
- `tpm2_*`
- `dracut`

Tests must not require root privileges.

### Artifact validation

Generated configuration may be inspected, parsed and validated.

Examples:

- dracut module structure
- generated kernel command lines
- generated rEFInd configuration
- UKI command-line contents
- expected initramfs file lists
- configuration file syntax

Artifact validation must not enroll keys, alter TPM state or modify block
devices.

---

## Testing philosophy

Prefer testing transformations:

    input -> logic -> expected output

rather than executing privileged operations.

Examples:

    PCR configuration
        ->
    cryptenroll argument builder
        ->
    expected argv[]

or:

    snapshot metadata
        ->
    snapshot menu model
        ->
    expected selectable entries

or:

    kernel version list
        ->
    UKI selection logic
        ->
    expected EFI paths

Functions that build command arguments should be separated from functions
that execute those commands.

---

## Definition of done

Before considering a Bash change complete:

1. inspect the affected architecture
2. inspect existing related code
3. implement the smallest coherent change
4. run syntax validation
5. run ShellCheck
6. run formatting validation
7. run applicable unit/static tests
8. inspect the final git diff
9. verify no secrets or generated private keys were added
10. report validations that could not safely be performed

Do not claim that boot, TPM enrollment, Secure Boot enrollment or disk
installation works merely because static tests pass.

Clearly distinguish:

- verified
- statically validated
- inferred
- not tested

---

## Change policy

Prefer minimal changes.

Do not:

- rename files unnecessarily
- reorganize unrelated code
- replace existing mechanisms merely because another approach is preferred
- change boot architecture while fixing an unrelated bug
- change paths or configuration formats without migration consideration

When modifying security-sensitive or boot-critical logic, explain the
behavioral change in the final response.