# Governance

HarmonyGo is a small, opinionated project. This document says who decides what,
so contributors do not have to guess.

## Roles

| Role | Who | Powers | Duties |
|---|---|---|---|
| **BDFL** | repository owner | final veto, releases, trademark, security response | publish roadmap, keep `AGENTS.md` authoritative |
| **Maintainer** | 1–3 invited people | merge PRs, triage issues, cut release candidates | review against `AGENTS.md`, demand device evidence |
| **Contributor** | anyone | PRs, issues, plugins, docs | DCO sign-off, tests, honest scope |

Maintainers are added by the BDFL when a contributor has a sustained record of
good reviews and platform judgment. Maintainers can step down at any time.

## Decisions

- **Everyday changes**: lazy consensus. A PR with no blocking review after 48
  hours may be merged by a maintainer.
- **Protocol / plugin contract / platform constraint changes**: open an RFC in
  `docs/rfcs/NNNN-*.md`. Minimum 7 days for comment; the BDFL decides after the
  comment window. The RFC must update `AGENTS.md` and affected docs in the same
  commit.
- **Security fixes**: private advisory first, public disclosure after a fix is
  available. See `SECURITY.md`.
- **Releases**: SemVer. `v1.x` does not break the plugin contract. Release notes
  list behavior changes, not file changes.

## Contribution license (DCO)

Every commit must carry a `Signed-off-by` line:

```bash
git commit -s -m "..."
```

This is the [Developer Certificate of Origin](https://developercertificate.org/):
you certify you have the right to submit the change under the project's MIT
license. No CLA is required.

## Roadmap

The public roadmap lives in `docs/ROADMAP.md` and `docs/MOAT-PLAN.md`. The BDFL
may decline work that does not fit the project's direction; the “not doing” list
in `docs/OPEN-SOURCE-STRATEGY.md` is part of the roadmap.

## Changes to this document

Governance changes follow the RFC process and require a BDFL decision. They are
not made by a drive-by PR.

## Code of conduct

Participation is covered by `CODE_OF_CONDUCT.md`. Maintainers may remove
comments, commits, or contributors that violate it.
