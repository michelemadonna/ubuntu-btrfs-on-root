# Invariants

These are change constraints, not a description of the full flow. Trace every
producer and consumer before altering one.

## Execution and devices

- Primary setup runs as root before first boot: from the post-Ubiquity live
  session for Ubuntu or against the selected fresh Kali installation. Both
  paths require manual partitioning and UEFI x86-64.
- Destructive targets must be explicit, distinct where required, real block
  devices and validated for expected type/source before mutation.
- Root starts as unencrypted Btrfs mounted at `mp`; the ESP is FAT and receives
  label `ESP` without reformatting.
- Kali mode may start with no filesystems mounted; setup mounts the configured
  root, ESP and optional separate `/boot` before conversion.
- An exact separate mount at `/target/boot` is optional and never created for
  discovery; the ESP path still remains `/target/boot/efi`.
- `setup.prepare_target` preserves target mounts except conditional
  `/target/cdrom`; successful completion leaves target mounts and mapper `root`
  open.
- Secrets and private keys never enter logs, summaries, tests or commits.

## Btrfs, boot and LUKS

- Suite containers are siblings below Btrfs top level: `@noble`, `@resolute`,
  never `@ubuntu/@noble`.
- Active root is `@$suite/@`; dedicated data subvolumes remain children of the
  same suite container.
- Root snapshots are `@$suite/@/.snapshots`; home snapshots are
  `@$suite/@home/.snapshots`. Only root snapshots are bootable.
- Do not delete original top-level data until root snapshot and relocations
  succeed.
- A configured separate boot is copied and validated in `@$suite/@/boot` before
  unmount; regenerated fstab contains `/boot/efi` but no separate `/boot`.
- `fstab` is regenerated from scratch using the UUIDs of the encrypted Btrfs
  filesystem and ESP, then includes the configured root, data and swap
  subvolume entries.
- Kali conversion validates `@`, `@home`, `@root`, `@usr@local`, `@var@log`
  and `@.snapshots`; it copies their root, home, root-account, local, cache and
  log data into the `@kali` layout, then deletes migrated top-level source
  subvolumes while preserving `@kali`.
- In-place encryption uses LUKS2 mapper `root`, reserves 32 MiB and identifies
  the volume by LUKS UUID in crypttab.
- `iter_time` is a positive Argon2id calibration target in milliseconds, not a
  literal iteration count.
- Preserve password/recovery access and non-TPM keyslots.

## Rescue

- `install_rescue=no` skips rescue and permits empty `rescue_dev`; the explicit
  standalone action still requires a target.
- When enabled, suggest `boot_dev` only if it satisfies
  `max(7168 MiB, source + 256 MiB) + 512 MiB`; refusal or ineligibility requires
  another selected partition.
- Reusing boot requires completed boot migration and explicit confirmation.
- Rescue requires GPT, exact target confirmation and a source different from
  the target. It rejects individual FAT files above 4095 MiB.
- Persistence is a separate trailing ext4 partition labelled `writable`; no
  file-backed persistence may be introduced.
- Rescue and persistence remain outside root encryption.

## Secure Boot

- Never disable verification as a workaround or replace an existing private
  signing hierarchy automatically.
- `secure_boot_enrollment` is the user's `sbctl`/`mok` choice;
  `secure_boot_mode` is only the detected `setup`/`enabled`/`disabled`/`unknown`
  state. No automatic fallback is allowed.
- Default direct enrollment is exactly `sbctl enroll-keys --microsoft` and can
  complete only in Setup Mode. Other states warn and skip enrollment.
- Partial db/KEK/PK append/preservation runs only with
  `EXPERIMENTAL_SBCTL_APPEND=true` and keeps PK last.
- MOK requests a PIN only for the MOK path and may be prepared with Secure Boot
  enabled or disabled.
- `$ESP/EFI/keys` contains only public `PK.pem`, `KEK.pem`, `db.pem` and optional
  `db.cer`; private `.key`, `.auth` and `.esl` material is forbidden.
- rEFInd, selected drivers, fwupd and every accepted UKI retain verified db
  signatures.
- EFI cleanup remains contained to validated immediate child trees containing a
  regular file named exactly `grubx64.efi`.

## UKI lifecycle

- Debian postinst/postrm bridge remains a thin `exec` adapter to
  `kernel-install add/remove` and propagates failure to package management.
- Add produces a signed versioned UKI; remove deletes the matching artifact.
- rEFInd menu regeneration is atomic and newest-first. The newest entry boots
  normally; `Tab` exposes every older installed version.
- Reject and remove a UKI that fails signature, required PE section, embedded
  version or configured initramfs-content validation.
- Keep `tpm2-pin=yes` in the command line for both PIN and PINless TPM modes.
- `generate-uki` remains standalone after repository removal.

## TPM

- Installation does not enroll a token; enrollment is explicit.
- Never clear the TPM or enroll during ordinary validation.
- Create a mode-0600 LUKS header backup before token changes.
- Normal enrollment preserves all existing access. Reseal removes only TPM2
  tokens and requires explicit wipe acknowledgement.
- PCR-policy or key changes may invalidate unlock and require documented
  resealing.
- `tpm-enroll`, `tpm-reseal` and `tpm-status` remain standalone.

## Snapshot boot

- No request, cancellation or any selector failure falls back to normal boot.
- Stop the listener and close its evdev descriptors before cryptsetup may
  prompt.
- Discover after LUKS availability and before real-root mount.
- Mount top level and selected snapshot read-only; runtime writes are ephemeral.
- Never delete or mutate a snapshot during validation.
- `/etc/snapshot-menu.conf` defaults remain `PAGE_SIZE=20`,
  `DESCRIPTION_MAX_LENGTH=24`, `SNAPSHOT_TRIGGER="F12"`,
  `SNAPSHOT_TRIGGER_WINDOW_TICKS=50`, `SNAPSHOT_TRIGGER_RESULT_TICKS=0`.
- The generated configuration records `SUITE`; every current-system label and
  snapshot-menu title is derived from it rather than a distribution literal.
- Ubuntu and Kali use the same evdev F12 trigger path; generated configurations
  do not enable the Plymouth character fallback.
- Kali must not use a trigger containing `Alt`, because it makes Plymouth leave
  the graphical splash and moves LUKS prompting to the text console.
- Ticks are 100 ms, description width is capped at 40, and changes require UKI
  regeneration.

## Configuration and installed artifacts

- Generated `setup.conf` is shell input, mode 0600 and secret-bearing. Wizard
  defaults do not depend on `setup.conf.example`.
- Wizard yes/no values remain literal toggles; suite and enrollment selections
  remain closed sets documented in `AGENTS.md`.
- `pre_download`, `enable_tpm` and `install_rescue` activate only on literal
  `yes`. `sb_key_dir` remains unused.
- Declining final wizard confirmation retains configuration and starts no
  installation work.
