# 🧪 Lab setup

Build a small, **fully isolated** virtual lab before running any dehardening script. The whole point
is that you can break things freely and roll back in seconds.

> [!WARNING]
> Everything here must stay on an **isolated (Host-Only) network**. A dehardened VM has no firewall,
> weak passwords, and cleartext services — it must never touch a real network or the internet beyond
> the one-time package installs.

## Recommended topology

| Role | Suggested OS | Purpose |
| --- | --- | --- |
| **Attacker** | Kali Linux (or any distro with `nmap`, `hydra`, `john`, `hashcat`, `netexec`) | Runs the "exploit" commands from each guide |
| **Victim — Linux** | Ubuntu Desktop 24.04 / 22.04 | Target for [docs/ubuntu-desktop.md](ubuntu-desktop.md) |
| **Victim — Windows** | Windows Server 2019 | Target for [docs/windows-server-2019.md](windows-server-2019.md) |

You don't need all three at once. A single victim VM plus an attacker box is enough to work through
one guide.

## Networking

1. In your hypervisor (VirtualBox, VMware, Hyper-V, …) create a **Host-Only / Internal** network.
2. Attach the attacker and victim VMs to that network **only**.
3. Confirm they can reach each other and nothing else:
   - Linux: `ip a` to read the VM's address, then `ping <other-vm>` across the lab.
   - Windows: `ipconfig` to read the address.
4. Use each victim's address as the `HOST` / `IP` placeholder in the exploit commands.

> Some dehardening steps install legacy packages (e.g. `telnetd`). If your lab has no internet, run
> the Ubuntu script with `--no-apt` to skip those installs, or install the packages beforehand.

## Snapshots — your undo button

Snapshots are what make this safe and repeatable.

1. Install the victim OS and apply any updates you want as a baseline.
2. **Take a snapshot and name it `fresh`** *before* running any dehardening script.
3. Run the script, exploit, and harden as the guide describes.
4. When you want a clean slate, **restore the `fresh` snapshot**.

Both scripts also keep their own backups so you can undo by hand if you prefer:

| System | Backups | Log |
| --- | --- | --- |
| Ubuntu | `/root/deharden-backups-<date>/` | `/var/log/deharden-lab.log` |
| Windows | `C:\deharden-backups-<date>\` (incl. `secpol-BEFORE.cfg`) | `C:\deharden-lab.log` |

## Suggested workflow

```text
  ┌─────────────┐   ┌───────────┐   ┌────────────┐   ┌─────────────┐
  │ 1. DEHARDEN │ → │ 2. EXPLOIT│ → │ 3. HARDEN  │ → │ 4. RESTORE  │
  │ run script  │   │ from the  │   │ apply fix, │   │ roll back   │
  │ on fresh VM │   │ attacker  │   │ re-attack  │   │ to snapshot │
  └─────────────┘   └───────────┘   └────────────┘   └─────────────┘
```

Work one weakness (one table row) at a time: exploit it, harden it, prove the attack now fails, then
move to the next. That direct before/after contrast is where the learning happens.

Ready? Pick a target:

- 🐧 [Ubuntu Desktop guide](ubuntu-desktop.md)
- 🪟 [Windows Server 2019 guide](windows-server-2019.md)
