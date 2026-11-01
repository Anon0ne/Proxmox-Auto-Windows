# Proxmox-Auto-Windows

Build unattended Proxmox VE installer ISOs on Windows.

Give it a stock Proxmox VE ISO (8.2 or newer). It generates `answer.toml`, embeds it in a copy
of the ISO, and gives you a new ISO to burn with Rufus.

It does the same thing as Proxmox's official
`proxmox-auto-install-assistant prepare-iso --fetch-from iso`, which only runs on Debian/Proxmox.

```powershell
git clone https://github.com/Anon0ne/Proxmox-Auto-Windows.git
cd Proxmox-Auto-Windows
.\New-ProxmoxAutoIso.ps1 -IsoPath C:\ISO\proxmox-ve_9.2-1.iso
```

If PowerShell blocks the script, run it with
`powershell -ExecutionPolicy Bypass -File .\New-ProxmoxAutoIso.ps1 ...`, or use `Build-AutoIso.cmd`.

## Requirements

One of these:

- **Docker Desktop** running (used automatically). On first run it builds a small
  `proxmox-autoiso-tools` image (Debian + xorriso + openssl).
- **WSL** with the tools installed:
  `wsl -d Ubuntu -- sudo apt-get install -y xorriso openssl`, then pass `-Backend WSL`.

## Usage

**Wizard** – drag the ISO onto `Build-AutoIso.cmd`, or run:

```powershell
.\New-ProxmoxAutoIso.ps1 -IsoPath C:\ISO\proxmox-ve_9.2-1.iso
```

It asks for hostname, root password, e-mail, timezone, keyboard, network (DHCP or static),
filesystem and target disks. It writes:

| File | What it is |
|---|---|
| `proxmox-ve_9.2-1-auto.iso` | the ISO to burn |
| `proxmox-ve_9.2-1-auto.answer.toml` | the answer file that was embedded |
| `proxmox-ve_9.2-1-auto.config.json` | your wizard answers, for reuse with `-Config` |

**From a config file** – for repeat builds or several hosts, copy `example-config.json`:

```powershell
.\New-ProxmoxAutoIso.ps1 -IsoPath .\proxmox-ve.iso -Config .\pve01.json -OutputPath .\pve01.iso
```

**Other options**

| Option | Purpose |
|---|---|
| `-AnswerFile answer.toml` | embed a hand-written answer file as-is |
| `-FirstBootScript setup.sh` | run a script once on first boot (8.3+, max 1 MiB, needs a shebang) |
| `-AnswerOnly` | only generate the answer file |
| `-PlainPassword` | keep the root password in plaintext instead of hashing it |
| `-KeyStyle Kebab\|Snake` | override key spelling (auto: snake_case before 8.4, kebab-case from 8.4) |
| `-Backend Docker\|WSL`, `-WslDistro` | choose where xorriso runs |
| `-Force` | overwrite existing output files |

## Config file format

The JSON mirrors the answer file sections (`global`, `network`, `disk-setup`, plus optional
`first-boot`, `post-installation-webhook`). Everything in the
[Proxmox answer file reference](https://pve.proxmox.com/wiki/Automated_Installation#Answer_File_Format_2)
works. Write keys in kebab-case. Keys that start with `_` are treated as comments.

- A plaintext `root-password` is converted to `root-password-hashed` (SHA-512 crypt) on 8.3+ ISOs,
  so the password itself never ends up on the ISO.
- **Disks**: `"disk-list": ["sda"]` uses Linux names on the *target* machine (`sda`, `nvme0n1`).
  Or select by udev property: `"filter": { "ID_SERIAL": "Samsung_SSD_*" }`. Every disk that
  matches gets wiped.
- **NIC for a static IP**: match by MAC with `"filter": { "ID_NET_NAME_MAC": "*aabbccddeeff" }`
  (lowercase, no colons), or by name with `"filter": { "ID_NET_NAME": "eno1" }`.
- **Unknown disk or NIC names**: boot the stock ISO, choose *Advanced Options → Install Proxmox VE
  (Terminal UI, Debug Mode)*, and run `proxmox-auto-install-assistant device-info -t disk`
  (or `-t network`).

The script checks the config before building: required keys, valid keyboard and country codes,
DHCP vs. static rules, disk count for the RAID level, and features your ISO version doesn't support.

## Burning with Rufus

1. Select the `-auto.iso` file and click **START**.
2. When Rufus asks, choose **Write in DD Image mode**. ISO mode does not boot Proxmox reliably.

## ⚠️ Safety

On boot the **Automated Installation** menu entry is selected by default and starts after a
short countdown. It **erases the configured disks without asking**. Label the USB stick, and
don't leave it plugged into a machine that boots from USB.

## Troubleshooting

- **Disk space**: the output drive needs about the ISO's size free (~1.7 GB). Use
  `-OutputPath D:\somewhere\pve01.iso` to build on a roomier drive. Docker only works on the
  ISO through a mounted folder, so no copy goes into Docker's own disk.
- **Docker not responding**: after 20 seconds the script gives up on Docker and tries WSL. If
  Docker Desktop won't start (for example a `wsl-bootstrap ... mkfs` error), run `wsl --shutdown`
  and start Docker Desktop again. A nearly full C: drive is a common cause.
- **Scripted wizard runs**: when input is piped in, the wizard reads the password from stdin
  instead of a hidden prompt.

## How it works

1. xorriso reads `/.cd-info` (product and version) and checks for `/auto-installer-capable`.
2. The answer file is built from your config, using the key spelling your ISO version expects.
3. The ISO is copied, and a new session is appended with `/answer.toml` and
   `/auto-installer-mode.toml` (`mode = "iso"`). The append uses
   `xorriso -boot_image any keep -volume_date uuid <original>`, so the BIOS/UEFI boot images and
   the volume UUID that GRUB looks for stay the same. This is the same call the official tool makes.
4. The new ISO is read back to confirm the answer file, the UUID and the capability flag.

## Tested

Checked with Proxmox VE 9.2-1 against the official `proxmox-auto-install-assistant`:

- `validate-answer` accepts the generated answer files.
- `inspect-iso` reads the built ISO as auto-install enabled, with the answer file embedded.
- Compared with an ISO from the official `prepare-iso`:
  - the first 32 KiB (MBR/GPT system area) is byte-identical;
  - `auto-installer-mode.toml` and the volume UUID are identical;
  - the only differences are the boot catalog's position and the total size, because the
    official tool appends one session per file and this script appends one session in total.

Not yet tested: booting the result on real hardware, and 8.x ISOs (snake_case keys).
