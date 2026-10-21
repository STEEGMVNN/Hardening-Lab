# Contributing

Thanks for your interest in improving **Hardening-Lab**! This is an open-source learning lab, and
contributions that make the exercises clearer, safer, or broader are very welcome.

## Ground rules

- **Lab-only by design.** Every script here must stay safe to run *only* in an isolated VM. Keep the
  big warning banner, the confirmation prompt, the backups, and the log in any script you add or edit.
- **Reversible.** A learner must always be able to undo a change — via the VM snapshot and via the
  script's own backups. Don't introduce a step that can't be rolled back.
- **Teach the "why".** Every weakness a script introduces should map to a row in the matching guide
  with all three columns filled in: the weakness, how it's exploited, and how to harden it.
- **Dual-use stays educational.** Exploitation commands are included only to let learners validate
  their own hardening. Keep them demonstrative, not weaponized.

## Ways to contribute

- **Improve a guide** — clearer explanations, better hardening commands, fixed typos.
- **Harden the scripts** — portability across OS versions, safer defaults, better logging.
- **Add a new target system** — see below.

## Adding a new target system

1. Add the script under `scripts/<system>/`.
2. Add a guide under `docs/<system>.md` using the same **run → exploit → harden** layout as the
   existing guides (three-column weakness table, "how to run", backups/log locations).
3. Link the new system from the table in [README.md](README.md) and from
   [docs/lab-setup.md](docs/lab-setup.md).

## Submitting changes

1. Fork the repository and create a branch (`git checkout -b improve-ubuntu-guide`).
2. Make your change and test the script in a throwaway VM.
3. Open a pull request describing what you changed and how you verified it.

## Style

- Scripts: keep the existing section structure (`step` / `ok` / `warn` helpers, numbered blocks).
- Docs: Markdown, English, GitHub-flavored. Prefer short rows and concrete commands over prose.
