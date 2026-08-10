# Ubuntu UKI + Snapper Boot Menu + TPM2

This repository provides two independent components:

- **UKI**
  - Generates Unified Kernel Images directly with Dracut and ukify.
  - Embeds the Snapper snapshot boot menu in the initrd.
  - Embeds the signed PCR 11 policy.
  - Signs the final UKI with `sbctl`.
  - Installs UKIs under `EFI/Linux/ubuntu/`.
  - Automatically runs after every kernel installation.
  - Keeps the latest two UKIs.

- **TPM**
  - Enrolls the LUKS2 root volume with TPM2.
  - Uses literal PCR bindings for PCR 7 and PCR 14.
  - Uses a signed policy for PCR 11.
  - Backs up the LUKS header before changing TPM tokens.
  - Remains separate from kernel installation.

## Repository layout

```text
ubuntu-uki/
├── README.md
├── uki/
│   ├── config/
│   │   ├── cmdline.example
│   │   ├── snapshot-menu.conf
│   │   └── uki.conf
│   ├── dracut/
│   │   └── 92snapshot-menu/
│   │       ├── module-setup.sh
│   │       └── snapshot-menu.sh
│   ├── hooks/
│   │   ├── postinst.d/
│   │   │   └── zz-generate-and-sign-uki
│   │   └── postrm.d/
│   │       └── zz-remove-uki
│   └── scripts/
│       ├── generate-and-sign-uki
│       ├── install-uki
│       ├── remove-uki
│       └── uninstall-uki
└── tpm/
    ├── config/
    │   └── tpm.conf
    └── scripts/
        ├── install-tpm
        ├── tpm-enroll
        ├── tpm-reseal
        ├── tpm-status
        └── uninstall-tpm
```
## Installation

```bash
sudo chronyc online
sudo chronyc burst 4/4
sleep 5
chronyc sources -v
sudo chronyc makestep
sudo apt install -y  git
git clone https://github.com/michelemadonna/ubuntu-btrfs-on-root.git ~/ubuntu-btrfs-on-root
cd ~/ubuntu-btrfs-on-root
git checkout one-subvol-per-distro
chmod a+x ubuntu-btrfs-root
sudo ./ubuntu-btrfs-root
```

## UKI installation

```bash
sudo ./uki/scripts/install-uki
```

The installer configures:

- the ESP mount point;
- the Btrfs filesystem UUID;
- the LUKS UUID;
- the normal root subvolume;
- PCR signing keys;
- the Dracut snapshot menu module;
- automatic kernel hooks.

UKIs are installed as:

```text
/boot/efi/EFI/Linux/<distribution>/<distribution>-<kernel-version>.efi
```

## TPM installation

Install the UKI component first, because TPM enrollment uses the PCR public key
created by the UKI installer.

```bash
sudo ./tpm/scripts/install-tpm
sudo /usr/local/sbin/tpm-enroll
```

The dual-boot-safe default policy is:

```text
Literal PCRs: 7
Signed PCR:   11
```

PCR 14 is optional. Add it only after confirming that PCR 14 has the same
value after booting both Ubuntu and Kali.

A normal kernel update does not require TPM re-enrollment. Every new UKI embeds
a new valid PCR 11 signature using the same signing key.

Use `tpm-reseal` only when intentionally replacing the TPM token, for example
after changing the selected PCRs or the PCR signing key.

## Manual UKI generation

```bash
sudo /usr/local/sbin/generate-and-sign-uki "$(uname -r)"
```

## Snapshot boot menu

Hold `B` during the configured detection window.

The menu:

- reads Snapper `info.xml` metadata;
- displays snapshot number, type, pre-number, date, user, cleanup algorithm,
  description, and userdata;
- warns when the selected snapshot does not contain the module directory for
  the kernel embedded in the selected UKI;
- mounts the selected snapshot read-only on `/sysroot`;
- leaves the existing Dracut overlay module responsible for the writable layer.

Plymouth is paused and hidden, but not terminated or deactivated. The script
does not reconfigure the framebuffer, DRM, KMS, `simpledrm`, or `/dev/fb0`.


## Ubuntu and Kali on the same LUKS volume

Install the UKI component independently in each distribution:

- use `ubuntu` as the distribution identifier on Ubuntu;
- use `kali` as the distribution identifier on Kali.

This produces:

```text
EFI/Linux/ubuntu/ubuntu-<kernel>.efi
EFI/Linux/kali/kali-<kernel>.efi
```

Both installations must use the same PCR signing key pair when they share one
LUKS TPM policy. Copy the existing key pair securely from Ubuntu to Kali:

```text
/etc/ubuntu-uki/keys/pcr-private.pem
/etc/ubuntu-uki/keys/pcr-public.pem
```

Preserve ownership and permissions:

```bash
chmod 0600 /etc/ubuntu-uki/keys/pcr-private.pem
chmod 0644 /etc/ubuntu-uki/keys/pcr-public.pem
```

With `TPM_LITERAL_PCRS="7"` and `TPM_SIGNED_PCRS="11"`, one existing TPM
enrollment can authorize UKIs from both distributions when both UKIs contain
PCR 11 signatures made with the shared private key.

If PCR 14 is required and differs between Ubuntu and Kali, run `tpm-enroll`
once from each distribution with:

```bash
TPM_LITERAL_PCRS="7+14"
TPM_WIPE_EXISTING="no"
```

This adds a second TPM2 token without deleting the first one. Never use
`tpm-reseal --wipe-all-tpm2` unless every existing Ubuntu and Kali TPM token is
intentionally being replaced.