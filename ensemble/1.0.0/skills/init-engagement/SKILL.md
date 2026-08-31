---
name: init-engagement
description: Stand up a NEW Ensemble engagement end-to-end so /tether and /handoff work against it. Use when a consultant wants to hand work off but the engagement doesn't exist yet — "there's no engagement for this", "onboard a new engagement", "create the engagement repo", "register this project with the Ensemble", "/tether says no match". Creates the GitHub engagement repo from the template, fills the scaffolding, applies the queue+main branch model, adds the registry row, and tethers to it.
---

# /init-engagement — onboard a new Ensemble engagement

`/tether` binds to an engagement and `/handoff` pushes work to it — but **both assume the
engagement already exists**. This is the missing first step: it **creates** one. After it
runs, the engagement is registered, polled by the Ensemble, and ready for `/handoff`.

It does, idempotently (re-runnable after any interruption — every step is create-if-not-exists):

1. **Creates the GitHub repo** `<owner>/sasam-<scope_tag>` from the
   `SAS-Asset-Management/sasam-engagement-template` template.
2. **Fills the scaffold** — renders the root `AGENTS.md` from `templates/AGENTS.md.tmpl`
   (the canonical instruction file, in the AAIF AGENTS.md format that every coding agent
   reads) and the root `CLAUDE.md` pointer from `templates/CLAUDE.md.tmpl`,
   fills `.ensemble/project.json` (uuid, name, scope_tag, repo, bucket, consultants, …) and
   `.lfsconfig` (tailnet + scope_tag), commits and pushes `main`.
3. **Applies the two-branch model** — runs the repo's `scripts/apply-branch-protection.sh`:
   creates the `queue` mailbox branch, protects `main` (PR required, the `tier-gate` check is
   the gate, auto-merge on), and creates the `tier:*` labels.
4. **Registers** the engagement in `sasam-registry` (`{uuid,name,scope_tag,repo,status:active}`)
   so the poller starts polling it.
5. **Tethers** the current session to it — then `/handoff` works immediately.

## Who runs this

The **founder** (or anyone with org rights). Creating an org repo, setting branch protection,
and pushing to the shared registry need founder GitHub credentials — run `gh auth login` first.
(This is the local, founder-run form of the spec's founder-tier `init-project`.)

## Prerequisites

- `gh` authenticated as a user with **admin on the `<owner>` org** and **push on `sasam-registry`**.
- `git`, `python3` (stdlib only — no pip).
- On the **Tailscale tailnet** (used to auto-derive the LFS endpoint tailnet; or pass `--tailnet`).

## How to run it

1. **Interview** the founder conversationally — gather:
   - **name** — the engagement display name (required).
   - **scope_tag** — kebab-case id; offer a default derived from the name, confirm it.
   - **consultants** — GitHub handles who work this engagement (default: the founder).
   - **review tier** — default approval tier (`auto|light|full|founder`, default `full`).
2. **Dry-run first** to show exactly what will be created (no changes):

```bash
bash "$SKILL_DIR/init_engagement.sh" --name "Yarra Trams MDR Assessment 2026" \
  --scope-tag yarra-trams-mdr --consultants scrivo21 --tier full --dry-run
```

3. **Create it** by dropping `--dry-run`:

```bash
bash "$SKILL_DIR/init_engagement.sh" --name "Yarra Trams MDR Assessment 2026" \
  --scope-tag yarra-trams-mdr --consultants scrivo21 --tier full
```

`$SKILL_DIR` is this skill's directory. Run it from the directory where you want the working
clone to land (or pass `--dir`). Useful flags: `--owner <org>` (default `SAS-Asset-Management`),
`--tailnet <name>`, `--no-tether` (create but don't tether), and
`--cleanup <scope_tag>` (delete a throwaway engagement: removes the repo + registry row).

## What you get back

A summary with the repo URL, `uuid`, `scope_tag`, and the `main`+`queue` branches, followed by
the `/tether` orientation. The engagement is now in the registry; the poller picks it up within
~2 minutes. **Next:** run `/handoff` to send your first packet.

## Notes

- **Idempotent.** Re-running for the same `scope_tag` makes no duplicate repo, branch, or
  registry row — it fills only what's missing and exits clean. Safe to re-run after a failure.
- **MinIO/LFS** needs no provisioning — the bucket is created lazily on first large-file write
  and LFS routes by `scope_tag` path.
- **Errors are loud:** a `403`/permission error means your `gh` account lacks org-admin or
  registry push; branch-protection needs admin on the new repo.
