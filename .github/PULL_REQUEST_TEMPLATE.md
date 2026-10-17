## Summary

<!-- What does this PR change, and why? -->

## Checklist

- [ ] If this touches `package.json`'s `engines`/`packageManager`, or `pnpm-workspace.yaml`
      (pnpm/Node version pins) — double-check `bootstrap-check` passed. A pnpm/TypeScript tooling
      bump from upstream Discourse silently broke production bootstrap on 2026-10-17; these
      fields are exactly where that regression started.
- [ ] If this brings in upstream Discourse commits, it's on its own sync branch/PR rather than
      pushed directly to `master`, so it goes through CI like any other change.
