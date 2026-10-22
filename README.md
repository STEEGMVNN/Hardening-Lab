<div align="center">

# 🛡️ Hardening Lab

**A hands-on, open-source lab for learning system hardening by breaking it first.**

Deliberately misconfigure a throwaway VM, watch how an attacker would exploit each flaw, then harden it back — one control at a time.

![Platform](https://img.shields.io/badge/platform-Ubuntu%20Desktop%20%7C%20Windows%20Server%202019-1f6feb)
![Shell](https://img.shields.io/badge/scripts-Bash%20%7C%20PowerShell-7ee3a7)
![License](https://img.shields.io/badge/license-MIT-brightgreen)
![Use](https://img.shields.io/badge/use-isolated%20lab%20VMs%20only-b42318)

</div>

---

> [!WARNING]
> These scripts **weaken a system's security on purpose**. Run them **only** inside an
> isolated lab VM (Host-Only network) with a **fresh-install snapshot** you can roll back to.
> **Never** run them on a real machine or on any network you care about.

---

## What is this?

Most hardening guides tell you *what* to configure but never let you *feel* why it matters.
This project flips that around. Each supported system ships with a **dehardening script** that
undoes common security controls, turning a clean VM into a realistic, vulnerable target. From there you:

1. **Deharden** — run the script on a fresh VM snapshot to introduce the weaknesses.
2. **Exploit** — reproduce how an attacker abuses each misconfiguration.
3. **Harden** — apply the fix and confirm the same attack now fails.
4. **Restore** — roll back to the snapshot and move on.

The result is a tight feedback loop: you break a control, you see the consequence, you fix it,
and you watch the consequence disappear. That's hardening you actually remember.

## Supported systems

| System | Script | Full guide |
| --- | --- | --- |
| 🐧 **Ubuntu Desktop** (24.04 / 22.04) | [`scripts/ubuntu/deharden-ubuntu.sh`](scripts/ubuntu/deharden-ubuntu.sh) | [docs/ubuntu-desktop.md](docs/ubuntu-desktop.md) |
| 🪟 **Windows Server 2019** | [`scripts/windows-server-2019/Deharden-WindowsServer2019.ps1`](scripts/windows-server-2019/Deharden-WindowsServer2019.ps1) | [docs/windows-server-2019.md](docs/windows-server-2019.md) |

> More systems may be added over time. Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## How each guide is organized

Every weakness follows the same four-part, fully reproducible pattern so the cause-and-effect is
always explicit — and so you can actually *run* each exercise end to end:

- 🧪 **Seeded by the script** — the exact artifact you can test (a user, a file mode, a policy).
- 🟠 **Exploit** — concrete attacker commands *and the result you should see* (e.g. the full
  "dump the hashes → crack them with `hashcat`" chain for the weak-password lesson).
- 🟢 **Harden** — the command that fixes it.
- ✅ **Re-test** — run the same attack again and confirm it now fails.

The scripts deliberately seed real, testable targets — weak accounts whose passwords are in common
wordlists, world-readable hashes, SUID binaries, open/legacy services, a vulnerable web app
(**DVWA**) you exploit to read `/etc/passwd`, and an optional outdated **ProFTPD** you patch instead
of delete — so the exploit steps aren't hypothetical: they succeed on a freshly dehardened VM and stop
succeeding once you harden it.

Each system guide also explains **how to run its script** and where backups and logs are written,
so you can always undo a change by hand if you prefer not to restore the snapshot.

## Quick start

```bash
# 1. Clone the project
git clone https://github.com/STEEGMVNN/Hardening-Lab.git
cd Hardening-Lab
```

Then follow the guide for your target system:

- **Ubuntu Desktop** → [docs/ubuntu-desktop.md](docs/ubuntu-desktop.md)
- **Windows Server 2019** → [docs/windows-server-2019.md](docs/windows-server-2019.md)

First time setting up the VMs? Start with **[docs/lab-setup.md](docs/lab-setup.md)** — it covers the
recommended topology (an attacker box plus the victim VMs), the Host-Only network, and snapshots.

## Repository layout

```
Hardening-Lab/
├── README.md                     ← you are here
├── LICENSE                       ← MIT
├── CONTRIBUTING.md               ← how to add a system or improve a guide
├── docs/
│   ├── lab-setup.md              ← build the isolated VM lab
│   ├── ubuntu-desktop.md         ← run → exploit → harden (Linux)
│   └── windows-server-2019.md    ← run → exploit → harden (Windows)
└── scripts/
    ├── ubuntu/
    │   ├── deharden-ubuntu.sh
    │   └── apparmor/
    │       └── usr.sbin.apache2     ← sample profile for the AppArmor exercise
    └── windows-server-2019/
        └── Deharden-WindowsServer2019.ps1
```

## Who this is for

Anyone learning defensive security hands-on: students, self-taught learners, blue teamers wanting a
safe range, or instructors who need a reproducible lab. No prior exploitation experience is required —
the guides give you the exact commands and explain what each one proves.

## Ethics & scope

The exploitation commands in the guides are **dual-use** and included purely so you can validate your
own hardening in an **isolated lab you control**. Do not point them at systems you are not explicitly
authorized to test. See the warning at the top of this file.

## License

Released under the [MIT License](LICENSE). Use it, fork it, teach with it.
