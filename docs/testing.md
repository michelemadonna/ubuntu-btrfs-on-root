# Validation and Testing Strategy

## 1. Purpose

This repository contains installation, storage, encryption and early-boot
logic that cannot always be safely executed in the normal development
environment.

The testing strategy therefore distinguishes between:

1. syntax validation;
2. static analysis;
3. unit and logic tests;
4. fixture-based tests;
5. artifact validation;
6. integration tests;
7. real-system validation.

The default agent validation path must use only non-destructive levels unless
a task explicitly provides a disposable integration environment.

---

## 2. Testing principles

Tests should validate logic without reproducing unnecessary system side
effects.

Prefer:

    input
      |
      v
    parser / decision / builder
      |
      v
    expected output

over:

    manipulate real system
      |
      v
    inspect whether it survived

Production code should therefore separate:

- state discovery;
- parsing;
- decision logic;
- command construction;
- command execution.

Example:

    read TPM configuration
            |
            v
    build_tpm_enrollment_args()
            |
            v
    execute systemd-cryptenroll

The argument builder can be tested independently from the real TPM.

---

## 3. Test levels

### Level 1 — Bash syntax validation

Every modified Bash script must pass:

    bash -n

This catches shell syntax errors.

All executable Bash files and sourced Bash libraries should be included.

Syntax validation is mandatory but does not demonstrate functional
correctness.

---

## 4. Level 2 — Static analysis

Modified Bash code must be analyzed using ShellCheck.

Preferred command:

    shellcheck <files>

Repository-wide validation may run ShellCheck against all relevant Bash
files.

ShellCheck warnings must not be suppressed without a documented reason.

### Formatting

The repository should use `shfmt` as the canonical Bash formatter.

Validation should normally run:

    shfmt -d .

Formatting checks must not automatically rewrite unrelated files during
validation.

A separate explicit formatting command may use:

    shfmt -w .

---

## 5. Level 3 — Unit and logic tests

Logic that does not require privileged system access should be extracted
into testable functions.

Recommended framework:

    bats-core

Good candidates include:

- PCR list parsing;
- TPM argument generation;
- LUKS token parsing;
- kernel version ordering;
- kernel retention decisions;
- UKI path generation;
- EFI path generation;
- Btrfs mount-option construction;
- rootflags transformation;
- Snapper list parsing;
- snapshot filtering;
- snapshot pagination;
- menu state transitions;
- snapshot kernel detection;
- PIN hash verification;
- configuration parsing;
- rEFInd stanza generation;
- marker-state decisions.

Tests should not require root.

---

## 6. Function design for testability

Prefer functions that return or populate structured values rather than
executing privileged commands directly.

Example:

```bash
tpm-enroll.build_pcr_argument() {
    local -a pcrs=("$@")
    local IFS=+
    printf '%s\n' "${pcrs[*]}"
}
```

Test:

```bash
@test "PCR values are joined with plus signs" {
    run tpm-enroll.build_pcr_argument 7 11 14

    [ "$status" -eq 0 ]
    [ "$output" = "7+11+14" ]
}
```

Avoid functions where parsing, business logic and destructive execution are
inseparably combined.

Instead of:

```bash
configure_everything() {
    cryptsetup ...
    parse_output ...
    systemd-cryptenroll ...
}
```

prefer:

```text
read_luks_state
        |
        v
parse_luks_state
        |
        v
decide_enrollment
        |
        v
build_enrollment_args
        |
        v
execute_enrollment
```

Only the final layer requires a real system.

---

## 7. Fixture-based testing

Commands whose output affects repository logic should be represented by test
fixtures.

Recommended layout:

```text
tests/
├── fixtures/
│   ├── blkid/
│   ├── btrfs/
│   ├── cryptsetup/
│   ├── findmnt/
│   ├── kernels/
│   ├── lsblk/
│   ├── snapper/
│   ├── tpm/
│   └── ukify/
└── unit/
```

Fixtures should capture representative outputs from supported environments.

Examples:

```text
tests/fixtures/cryptsetup/
├── luksdump-no-tpm.txt
├── luksdump-tpm-token.txt
└── luksdump-multiple-tokens.txt
```

```text
tests/fixtures/findmnt/
├── normal-btrfs-root.txt
├── snapshot-overlay-root.txt
└── chroot-root.txt
```

Fixtures must never contain real:

- passphrases;
- recovery keys;
- Secure Boot private keys;
- TPM secrets;
- PINs;
- machine-specific sensitive identifiers unless sanitized.

---

## 8. Mocking external commands

Tests may replace external system commands using:

- PATH-based mocks;
- Bash functions;
- wrapper functions;
- fixture readers.

Example test environment:

```text
tests/mocks/bin/
├── btrfs
├── cryptsetup
├── findmnt
├── lsblk
├── snapper
├── systemd-cryptenroll
└── tpm2_pcrread
```

A test may prepend this directory:

```bash
PATH="$TEST_ROOT/mocks/bin:$PATH"
```

Mock commands should:

1. validate received arguments;
2. emit fixture output;
3. return a controlled exit status;
4. avoid modifying the host.

---

## 9. Command-builder tests

Any security-sensitive command whose arguments are generated dynamically
should ideally have a testable argument-building layer.

Examples:

```text
build_cryptsetup_args
build_cryptenroll_args
build_dracut_args
build_ukify_args
build_mount_args
build_refind_entry
build_btrfs_mount_options
```

Tests should verify the exact argument vector rather than a flattened shell
string when possible.

Avoid constructing commands using `eval`.

Prefer arrays.

---

## 10. Configuration tests

Configuration files should be validated independently from system execution.

Tests should cover:

- missing required variables;
- empty values;
- invalid integer ranges;
- invalid paths;
- unsupported PCR values;
- malformed trigger keys;
- invalid pagination values;
- invalid timeout values;
- incomplete PIN configuration;
- contradictory options.

Tests should distinguish:

- defaulted optional values;
- required values;
- security-sensitive values.

---

## 11. Snapshot-menu tests

Snapshot-menu logic is a high-priority test target because much of it can be
validated without booting.

Tests should cover:

### Snapshot parsing

- empty snapshot list;
- one snapshot;
- multiple snapshots;
- malformed Snapper output;
- special characters in descriptions;
- missing metadata.

### Ordering

- newest first;
- oldest first if configured;
- stable behavior for equal timestamps.

### Pagination

Given a configured page size:

    PAGE_SIZE=20

verify:

- first page;
- middle page;
- last partial page;
- fewer snapshots than one page;
- exact multiple of page size;
- page navigation boundaries.

### Kernel availability

Verify detection when:

- current kernel exists in snapshot;
- current kernel is absent;
- multiple kernel versions exist;
- expected files are missing.

### Cancellation

Test defined behavior for:

- Ctrl-C;
- escape;
- EOF;
- timeout;
- invalid input.

### PIN

If snapshot PIN protection is enabled, test:

- correct PIN;
- incorrect PIN;
- malformed stored hash;
- missing salt;
- missing hash;
- PIN disabled.

Fixtures must use fake PINs only.

---

## 12. Snapshot-trigger tests

The keyboard listener itself may require lower-level testing, but its
surrounding state logic should be testable.

Verify:

```text
no marker
    ->
normal boot

valid trigger
    ->
marker created

listener timeout
    ->
no marker

listener termination
    ->
input ownership released
```

Tests must not interfere with the developer's actual input devices.

Do not automatically open or grab real `/dev/input/event*` devices during
normal validation.

Listener integration tests belong in a disposable environment.

---

## 13. Boot-state transition tests

Boot behavior should be represented as explicit state transitions where
possible.

Example states:

```text
TRIGGER_WAIT
LUKS_UNLOCK
SNAPSHOT_DISCOVERY
SNAPSHOT_SELECTION
ROOT_CONFIGURATION
NORMAL_BOOT
SNAPSHOT_BOOT
FAILURE
```

Tests should validate allowed transitions.

For example:

```text
TRIGGER_WAIT
    |
    | no request
    v
LUKS_UNLOCK
    |
    v
NORMAL_BOOT
```

and:

```text
TRIGGER_WAIT
    |
    | requested
    v
LUKS_UNLOCK
    |
    v
SNAPSHOT_DISCOVERY
    |
    v
SNAPSHOT_SELECTION
    |
    v
SNAPSHOT_BOOT
```

Snapshot discovery before successful LUKS unlock should be considered an
invalid transition.

---

## 14. Btrfs tests

Btrfs-related pure logic should be tested using fixtures.

These tests may source non-executing phase scripts from `btrfs-root/`, but
testability alone must not cause helpers to be moved into the top-level common
framework or an otherwise unnecessary feature-level common file.

Tests call production functions through their qualified names, such as
`fstab-setup.build_entries` and `luks-setup.build_crypttab_entry`. This also
checks that ownership remains explicit at the call site.

Examples include:

- subvolume path construction;
- snapshot path construction;
- rootflags generation;
- mount-option preservation;
- overlay lowerdir selection;
- detection of current root state.
- construction of the complete configured subvolume path list;
- generated target `fstab` root and data-subvolume entries;
- rejection of `/` or non-absolute target mount points.
- preservation of visible and hidden entries when directory contents move to
  dedicated data subvolumes.

Tests must include both:

- normal Btrfs root;
- overlay-backed snapshot boot.

Repository validation must not mount or modify real Btrfs subvolumes merely
to execute unit tests.

---

## 15. LUKS tests

LUKS tests should focus on parsing and decision logic.

Examples:

- detect presence of `systemd-tpm2` token;
- detect multiple tokens;
- detect missing token;
- preserve recovery mechanisms;
- construct enrollment arguments;
- reject invalid device configuration.
- construct the target `crypttab` entry from a post-encryption LUKS UUID;
- mock `blkid` when validating UUID discovery;
- verify that summaries and logs never contain the configured passphrase.

The Btrfs-root coordinator summary should be artifact-tested for the resolved
source partition, mapper, normal root subvolume, swapfile, target `fstab` and
target `crypttab`. Summary tests must call pure formatting helpers or mocks;
they must not source an entry point that starts the destructive storage phase.

Normal validation must not execute:

    cryptsetup luksFormat
    cryptsetup luksKillSlot
    systemd-cryptenroll

against a real device.

Read-only commands should still be mocked by default if they depend on host
state.

---

## 16. TPM tests

Unit tests should cover:

- PCR list parsing;
- PCR policy normalization;
- PCR bank selection;
- expected enrollment arguments;
- interpretation of TPM command output;
- detection of TPM availability.

Normal validation must not:

- clear TPM state;
- enroll keys;
- reset ownership;
- change persistent TPM configuration.

Real TPM tests require a dedicated environment.

---

## 17. Secure Boot tests

Static and artifact validation should verify:

- expected EFI paths;
- expected signing configuration;
- presence of required public certificates;
- generated signing commands;
- correct selection between direct and shim paths;
- absence of private keys from repository content.

Normal tests must not modify:

- PK;
- KEK;
- db;
- dbx;
- MOK state;
- EFI variables.

### Trust-path logic

Given simulated firmware state, tests should validate project policy.

Example:

```text
SetupMode=1
    ->
direct enrollment path

SetupMode=0
    ->
preserve firmware trust hierarchy
    ->
shim/MOK path
```

This validates project behavior without touching firmware.

---

## 18. UKI artifact validation

When a test UKI artifact is available, validation may inspect it without
booting it.

Possible checks include:

- PE/COFF structure;
- expected UKI sections;
- embedded command line;
- Secure Boot signature presence;
- expected kernel version;
- expected initramfs inclusion.

Tools may include:

```text
file
objdump
objcopy
sbverify
ukify
```

Tests must distinguish:

```text
artifact structurally valid
```

from:

```text
artifact confirmed bootable
```

The former does not prove the latter.

---

## 19. dracut module validation

The custom dracut module should have repository-specific validators.

Check statically that expected files exist.

Example:

```text
module directory
    |
    +-- module-setup.sh
    +-- expected hooks
    +-- snapshot-menu executable
    +-- listener executable
    +-- required configuration
```

Validators should check:

- required Bash functions in `module-setup.sh`;
- referenced source files exist;
- installed files exist;
- installed binaries use expected paths;
- hook paths are internally consistent;
- required configuration is included;
- no stale filename references remain.

When a test initramfs can safely be generated, it may additionally be
inspected using tools such as `lsinitrd`.

Generating an initramfs is still artifact validation, not a boot test.

---

## 20. rEFInd tests

Generated rEFInd configuration should be validated as text/artifacts.

Tests should cover:

- newest kernel selection;
- older-kernel submenu generation;
- EFI path generation;
- distro prefix handling;
- icon path generation;
- kernel removal behavior;
- empty kernel list.

Validation must not modify firmware boot variables.

---

## 21. Common framework tests

The common Bash framework should have dedicated tests.

Test at least:

### Logging

- info output;
- warning output;
- error output;
- quiet mode if supported.

### Command execution

- successful command;
- failed command;
- captured stderr;
- dry-run mode;
- exit-status propagation.

### Cleanup

- registered cleanup execution;
- multiple cleanup handlers;
- failure during cleanup;
- idempotent cleanup where required.

### Input

Where feasible without using a real TTY:

- default values;
- invalid input;
- confirmation parsing;
- PIN verification helpers.

---

## 22. Validation command

The repository should expose one canonical validation entry point.

Recommended:

```text
./scripts/validate
```

The agent should not need to remember every underlying tool.

A typical validation pipeline is:

```text
./scripts/validate
       |
       +-- bash -n
       |
       +-- ShellCheck
       |
       +-- shfmt -d
       |
       +-- Bats
       |
       +-- repository validators
       |
       +-- secret scanning
       |
       `-- result
```

The command must be safe to run on a normal development machine.

---

## 23. Suggested validation modes

As the repository grows, validation may support levels.

Example:

```text
./scripts/validate static
./scripts/validate unit
./scripts/validate artifacts
./scripts/validate all
```

Recommended meaning:

### `static`

Run:

- `bash -n`;
- ShellCheck;
- formatting checks.

### `unit`

Run:

- pure logic tests;
- fixture-based tests;
- mocked command tests.

### `artifacts`

Run:

- generated configuration validation;
- dracut structure validation;
- UKI inspection where available;
- rEFInd generation validation.

### `all`

Run every safe non-destructive validation.

`all` must not imply destructive integration testing.

---

## 24. Secret scanning

The repository should include secret scanning.

A suitable tool is Gitleaks or an equivalent scanner.

Validation should detect accidental commits of:

- private keys;
- passwords;
- tokens;
- recovery keys;
- API credentials.

Test fixtures containing fake secret-like data may require tightly scoped
allowlisting.

Allowlisting must not broadly disable scanning.

---

## 25. CI validation

CI should run the same canonical validation command used locally.

Prefer:

```text
CI
 |
 v
./scripts/validate all
```

rather than independently reimplementing the validation logic inside the CI
workflow.

This prevents divergence between local validation and CI behavior.

If GitHub Actions is used, workflow files should also be statically checked
with an appropriate workflow validator.

---

## 26. Integration testing

Some behavior cannot be proven through static or unit tests.

Examples include:

- actual Secure Boot execution;
- actual firmware signature acceptance;
- TPM PCR measurements;
- TPM auto-unlock;
- real LUKS unlocking;
- dracut hook ordering during boot;
- keyboard-event behavior during initramfs;
- real snapshot boot;
- OverlayFS root behavior;
- switch_root behavior.

These require an isolated integration environment.

Integration testing must not use the developer workstation as a disposable
target.

---

## 27. Future disposable integration environment

A future integration environment may use:

```text
QEMU
  |
  +-- OVMF / UEFI
  |
  +-- virtual Secure Boot state
  |
  +-- swtpm
  |
  +-- disposable virtual disk
  |
  `-- serial console
```

This could allow automated validation of:

```text
installation
     |
     v
Secure Boot
     |
     v
UKI
     |
     v
TPM unlock
     |
     v
snapshot trigger
     |
     v
snapshot boot
```

Such infrastructure is optional and separate from the normal repository
validation path.

---

## 28. Test classification

Validation results must use precise terminology.

### Verified

The behavior was actually exercised in an environment capable of testing it.

### Statically validated

Syntax, structure or generated artifacts were checked without executing the
real behavior.

### Unit tested

The relevant isolated logic was executed with controlled inputs.

### Inferred

The behavior follows from code inspection or related tests but was not
directly exercised.

### Not tested

No meaningful validation was performed for that behavior.

Agents must not report a boot-critical feature as "working" when only static
validation was performed.

---

## 29. Definition of done

Before considering a code change complete, run all applicable safe validation.

At minimum for Bash changes:

```text
bash -n
ShellCheck
shfmt check
relevant unit tests
repository validators
```

Then inspect:

```text
git diff
```

Verify:

- no unrelated changes;
- no generated private material;
- no secrets;
- no accidental path changes;
- no broken documentation references.

For boot/security changes, explicitly report which behaviors were:

- unit tested;
- statically validated;
- artifact validated;
- not executable in the current environment.

---

## 30. Relationship with repository instructions

`AGENTS.md` defines when validation must be performed.

This document defines how validation works.

`docs/invariants.md` defines which properties tests should protect.

`docs/boot-flow.md` defines valid runtime ordering.

`docs/architecture.md` defines the system structure.

Tests should therefore be derived from these documents rather than evolving
independently from the architecture.
