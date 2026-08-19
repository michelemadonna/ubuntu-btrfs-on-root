# Invariants

These constraints survive every change. Trace affected producers, artifacts
and consumers before editing behavior.

## Execution, migration and devices

- Primary setup requires root and a pre-first-boot UEFI x86-64 live session;
  migration accepts only fresh distribution installations.
- Destructive targets are explicit real block devices, distinct where required,
  and validated for expected type/source before mutation.
- Migration starts with unencrypted Btrfs at `mp`; its FAT ESP is labelled `ESP`
  without reformatting.
- Kali migration may start unmounted; setup mounts root, ESP and optional
  `/boot`. Discovery never creates `/target/boot`; if present it is exact, while
  ESP remains `/target/boot/efi`.
- `setup.prepare_target` preserves target mounts except conditional
  `/target/cdrom`; success leaves target mounts and mapper `root` open.
- Secrets and private keys never enter logs, summaries, tests or commits.

## Btrfs, boot and LUKS

- Suite containers are top-level siblings (`@noble`, `@resolute`, `@kali`),
  never `@ubuntu/@noble`; active root is `@$suite/@` and data stays under its
  suite. Only `@$suite/@/.snapshots`, not `@$suite/@home/.snapshots`, boots.
- Original top-level data remains until root snapshot and relocations succeed.
- A separate boot is copied and validated at `@$suite/@/boot` before unmount;
  regenerated fstab keeps `/boot/efi` but no separate `/boot`.
- `fstab` is regenerated from encrypted-Btrfs/ESP UUIDs with configured root,
  data and swap subvolumes.
- Kali conversion validates `@`, `@home`, `@root`, `@usr@local`, `@var@log`
  and `@.snapshots`; it migrates root, home, root-account, local, cache and log
  data, then removes source subvolumes while preserving `@kali`.
- In-place LUKS2 uses mapper `root`, reserves 32 MiB and records its UUID in
  crypttab. `iter_time` is a positive Argon2id millisecond target, not a count.
- Password/recovery access and non-TPM keyslots remain recoverable.

## New installation

- New installation accepts only an unused whole disk, neither live/root source
  nor mounted, swapped or held. Identity, size and layout are revalidated; the
  exact path is typed before `sgdisk`.
- GPT order is ESP, optional 10240 MiB rescue reserve, encrypted Linux root and,
  only with percentage root sizing, optional MSR, Windows and Windows RE.
  Partitions are resolved uniquely by GPT label after udev settles.
- `root_size_strategy=all` forbids Windows; insufficient percentage space
  returns to sizing before mutation.
- Fresh LUKS2 mapper `root` and suite/data subvolumes precede `debootstrap`;
  reencryption is not used.
- New installations create the requested initial user with its password and
  membership in the `sudo` group; setup does not request a root password.
- New installation preflight requires amd64, UEFI, reachable distribution
  archive DNS and a stable unchanged target-disk identity before destruction.
- A new Ubuntu target installs and manually marks the required desktop,
  language/input-method, VMware and base package set after `debootstrap`;
  this policy does not apply to Kali.
- Ubuntu new-install HWE selection maps exactly `resolute` to
  `linux-generic-hwe-26.04` and `noble` to `linux-generic-hwe-24.04`; no HWE
  prompt or package is used for Kali or migration.
- New-installation checkpoints in `NEW_INSTALL_PHASE` are persisted atomically;
  destructive phases are never marked complete before their commands succeed,
  and a rerun never recreates a completed GPT, filesystem, LUKS, subvolume or
  bootstrap phase.
- Common chroot checkpoints are persisted atomically in the target at
  `/var/lib/ubuntu-btrfs-on-root/install-phase`; Secure Boot, Snapper and UKI
  are skipped only after their preceding command succeeds.
- The configured Btrfs swapfile is mode 0600 and has a `/swap/swapfile` fstab
  entry before the new-installation validation succeeds.
- Kali verifies downloaded archive keys against the pinned official fingerprint;
  signatures stay enabled. Ubuntu uses archive/security plus `main restricted
  universe multiverse`; Kali uses only `kali-rolling` plus `main contrib non-free
  non-free-firmware`. Mirrors/keyrings never mix.
- Requested rescue requires a live source containing `casper/`. Resolved root,
  ESP and rescue devices atomically replace placeholders after GPT creation and
  before the repository is copied into the target.

## Rescue

- `install_rescue=no` skips rescue and permits empty `rescue_dev`; standalone
  rescue still needs a target.
- Suggest `boot_dev` only if it satisfies
  `max(7168 MiB, source + 256 MiB) + 512 MiB`; refusal or ineligibility requires
  another partition. Reuse also requires completed boot migration and explicit
  confirmation.
- Rescue requires GPT, exact target confirmation, a distinct source and no FAT
  file above 4095 MiB.
- Persistence is a separate trailing ext4 partition labelled `writable`, never
  a file. Rescue and persistence remain outside root encryption.
- New installation reserves exactly 10240 MiB before the rescue installer
  splits it into FAT live and trailing ext4 persistence.

## Secure Boot

- Never bypass verification or automatically replace a private signing hierarchy.
- `secure_boot_enrollment` is the user's `sbctl`/`mok` choice;
  `secure_boot_mode` is only detected `setup`/`enabled`/`disabled`/`unknown`.
  Detection never changes the selected path.
- Direct enrollment is exactly `sbctl enroll-keys --microsoft`, only in Setup
  Mode; other states warn and skip it.
- Partial db/KEK/PK append/preservation runs only with
  `EXPERIMENTAL_SBCTL_APPEND=true` and keeps PK last.
- `mok_pin` is required only for MOK, which may be prepared with Secure Boot
  enabled or disabled.
- `$ESP/EFI/keys` contains only public `PK.pem`, `KEK.pem`, `db.pem` and optional
  `db.cer`; private `.key`, `.auth` and `.esl` material is forbidden.
- rEFInd, selected drivers, fwupd and every accepted UKI retain verified db
  signatures.
- EFI cleanup is limited to validated immediate child trees containing a
  regular file named exactly `grubx64.efi`.

## UKI lifecycle

- Debian postinst/postrm remains a thin `exec` to `kernel-install add/remove`,
  propagating failure to package management.
- Add creates a signed versioned UKI; remove deletes its matching artifact.
- rEFInd regeneration is atomic/newest-first; newest boots normally and `Tab`
  exposes all older installed versions.
- Reject and remove UKIs failing signature, required PE section, embedded
  version or configured initramfs-content validation.
- Keep `tpm2-pin=yes` in the command line for PIN and PINless TPM modes.
- `/usr/sbin/generate-uki` remains standalone after repository removal.

## TPM

- Installation never enrolls; explicit enrollment is separate. Validation never
  clears TPM or enrolls.
- Create a mode-0600 LUKS header backup before token changes.
- Enrollment preserves all access; reseal removes only TPM2 tokens after
  explicit wipe acknowledgement.
- PCR-policy or key changes may invalidate unlock and require documented
  resealing.
- `tpm-enroll`, `tpm-reseal` and `tpm-status` remain standalone in `/usr/sbin`.

## Snapshot boot

- No request, cancellation or selector failure means normal boot.
- Stop the listener and close evdev descriptors before cryptsetup may prompt;
  discovery runs after LUKS availability and before real-root mount.
- Top level and selected snapshot are read-only; writes are ephemeral and
  validation never mutates snapshots.
- `/etc/snapshot-menu.conf` defaults remain `PAGE_SIZE=20`,
  `DESCRIPTION_MAX_LENGTH=24`, `SNAPSHOT_TRIGGER="B"`,
  `SNAPSHOT_TRIGGER_WINDOW_TICKS=50`, `SNAPSHOT_TRIGGER_RESULT_TICKS=0`.
- Generated configuration records `SUITE`; labels/titles derive from it, never a
  distribution literal.
- Ubuntu and Kali share the evdev B/b path; generated configurations do not
  enable the Plymouth character fallback. Kali triggers never contain `Alt`,
  which would move Plymouth and LUKS prompting to the text console.
- Ticks are 100 ms, description width is capped at 40, and changes require UKI
  regeneration.

## Configuration and artifacts

- Generated `setup.conf` is sourced, mode 0600 and secret-bearing; wizard
  defaults ignore `setup.conf.example`.
- Wizard choices: `install_mode` = `migration`/`new`; `root_size_strategy` =
  `all`/`percent`; `suite`/`suite_type` = `resolute` or `noble` with `ubuntu`,
  or `kali`/`kali`; `secure_boot_enrollment` = `sbctl`/`mok`; detected
  `secure_boot_mode` = `setup`/`enabled`/`disabled`/`unknown`;
  `EXPERIMENTAL_SBCTL_APPEND` = `true`/`false`.
- Yes/no fields stay literal: only `yes` activates `pre_download`, `enable_tpm`
  or `install_rescue`; `sb_key_dir` remains unused.
- Declining final wizard confirmation retains configuration and starts no
  installation work.
