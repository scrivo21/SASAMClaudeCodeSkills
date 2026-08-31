#!/usr/bin/env bash
# init_engagement.sh — /init-engagement: stand up a NEW Ensemble engagement end-to-end.
#
# The onboarding step the protocol was missing: /tether and /handoff both assume the
# engagement already exists. This creates one — GitHub repo from the template, filled
# scaffolding, the two-branch model (main protected + tier-gate, queue mailbox), and a
# registry row — then tethers to it so /handoff works immediately.
#
# FOUNDER action: creating an org repo, setting branch protection, and pushing to the
# shared registry require founder GitHub credentials (gh authenticated as the owner).
#
# Idempotent / re-runnable (spec §9): every external mutation is create-if-not-exists,
# so a half-finished run can be re-run to completion. Errors -> stderr + non-zero exit.
# Never prints secrets. Australian English throughout.
set -euo pipefail

_LIB="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" && pwd)"
# shellcheck source=/dev/null
. "$_LIB/ensemble_common.sh"

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_PY="$HERE/init_engagement_state.py"
TETHER_SH="$HERE/../tether/tether.sh"

TEMPLATE_DEFAULT="SAS-Asset-Management/sasam-engagement-template"
OWNER_DEFAULT="SAS-Asset-Management"
PROTOCOL_VERSION="1.2"

usage() {
  cat >&2 <<'EOF'
usage: init_engagement.sh --name <name> [--scope-tag <kebab>] [--consultants a,b]
                          [--tier auto|light|full|founder] [--owner <org>]
                          [--tailnet <name>] [--dir <dir>] [--dry-run] [--no-tether]
       init_engagement.sh --cleanup <scope_tag>     # delete a throwaway engagement

  --name         engagement display name (required, unless --cleanup).
  --scope-tag    kebab-case id (default: derived from --name).
  --consultants  comma-separated GitHub handles (default: you).
  --tier         default review tier (default: full).
  --owner        GitHub org for the repo (default: SAS-Asset-Management).
  --tailnet      tailnet name for the LFS endpoint (default: from `tailscale status`).
  --dir          where to clone the working copy (default: current directory).
  --dry-run      validate + print the plan; make NO changes.
  --no-tether    do everything except the final /tether.
  --cleanup      tear down a throwaway engagement (delete repo + remove registry row).
EOF
  exit 2
}

# --- parse args --------------------------------------------------------------
NAME="" SCOPE="" CONSULTANTS="" TIER="full" OWNER="$OWNER_DEFAULT"
TAILNET="" TARGET_DIR="" DRY=0 NO_TETHER=0 CLEANUP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)        NAME="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --scope-tag)   SCOPE="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --consultants) CONSULTANTS="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --tier)        TIER="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --owner)       OWNER="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --tailnet)     TAILNET="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --dir)         TARGET_DIR="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --cleanup)     CLEANUP="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --dry-run)     DRY=1; shift ;;
    --no-tether)   NO_TETHER=1; shift ;;
    -h|--help)     usage ;;
    *) ens_die "unknown argument: $1" ;;
  esac
done

ens_have git
ens_have gh
ens_have python3
ens_ensure_git_auth

TEMPLATE="${ENSEMBLE_TEMPLATE_REPO:-$TEMPLATE_DEFAULT}"

# --- registry mirror helpers (mirrors tether.sh) -----------------------------
REG_URL="$(ens_registry_repo)"
REG_DIR="$(python3 -c 'import ensemble_common as e; print(e.registry_dir())')"

normalise_remote() {
  local spec="$1"
  case "$spec" in
    *://*|*@*:*)    printf '%s\n' "$spec"; return ;;
    /*|./*|../*|~*) printf '%s\n' "$spec"; return ;;
  esac
  if printf '%s' "$spec" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    printf 'https://github.com/%s.git\n' "$spec"
  else
    printf '%s\n' "$spec"
  fi
}

refresh_registry() {
  local remote; remote="$(normalise_remote "$REG_URL")"
  if [ -d "$REG_DIR/.git" ]; then
    git -C "$REG_DIR" pull --ff-only >/dev/null 2>&1 \
      || printf 'ensemble: WARNING — could not refresh the registry mirror; using the cached copy.\n' >&2
  else
    rm -rf "$REG_DIR"
    git clone "$remote" "$REG_DIR" >/dev/null 2>&1 \
      || ens_die "could not clone the registry from '$REG_URL'. Check ~/.ensemble/config.json registry_repo and your access."
  fi
  [ -f "$REG_DIR/registry.json" ] || ens_die "registry.json is missing from the registry mirror at $REG_DIR."
}

# --- cleanup mode ------------------------------------------------------------
if [ -n "$CLEANUP" ]; then
  REPO="$OWNER/sasam-$CLEANUP"
  printf 'ensemble: cleaning up throwaway engagement %s ...\n' "$REPO" >&2
  if gh repo view "$REPO" >/dev/null 2>&1; then
    gh repo delete "$REPO" --yes >/dev/null 2>&1 \
      && printf 'ensemble: deleted repo %s\n' "$REPO" >&2 \
      || printf 'ensemble: WARNING — could not delete %s (need delete_repo scope: gh auth refresh -s delete_repo).\n' "$REPO" >&2
  else
    printf 'ensemble: repo %s does not exist — nothing to delete.\n' "$REPO" >&2
  fi
  refresh_registry
  if [ "$(python3 "$STATE_PY" registry-remove "$CLEANUP")" = "removed" ]; then
    git -C "$REG_DIR" add registry.json
    git -C "$REG_DIR" commit -q -m "chore(registry): remove $CLEANUP (cleanup)" >/dev/null 2>&1 || true
    git -C "$REG_DIR" push >/dev/null 2>&1 \
      && printf 'ensemble: removed %s from the registry.\n' "$CLEANUP" >&2 \
      || printf 'ensemble: WARNING — could not push the registry removal.\n' >&2
  else
    printf 'ensemble: %s was not in the registry.\n' "$CLEANUP" >&2
  fi
  exit 0
fi

# --- validate inputs ---------------------------------------------------------
[ -n "$NAME" ] || { printf 'ensemble: --name is required.\n' >&2; usage; }
case "$TIER" in auto|light|full|founder) : ;; *) ens_die "--tier must be auto|light|full|founder, not '$TIER'." ;; esac

[ -n "$SCOPE" ] || SCOPE="$(python3 "$STATE_PY" slug "$NAME")"
python3 "$STATE_PY" validate-scope "$SCOPE" || exit 2

REPO="$OWNER/sasam-$SCOPE"
REPO_BASE="sasam-$SCOPE"
TARGET_DIR="${TARGET_DIR:-$PWD}"
[ -d "$TARGET_DIR" ] || ens_die "target directory does not exist: $TARGET_DIR"
TARGET_DIR="$(CDPATH= cd -- "$TARGET_DIR" && pwd)"

# Founder handle + consultants + tailnet + timestamps.
FOUNDER="$(gh api user --jq .login 2>/dev/null || git config user.name 2>/dev/null || echo unknown)"
[ -n "$CONSULTANTS" ] || CONSULTANTS="$FOUNDER"
CONSULTANTS_JSON="$(python3 "$STATE_PY" consultants-json "$CONSULTANTS")"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -z "$TAILNET" ]; then
  TAILNET="$(tailscale status --json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("MagicDNSSuffix","").removesuffix(".ts.net"))' 2>/dev/null || true)"
fi
[ -n "$TAILNET" ] || ens_die "could not determine the tailnet (is Tailscale up?). Pass --tailnet <name> (e.g. tail060c48)."

# --- idempotency / collision probe -------------------------------------------
refresh_registry
REG_HIT="$(python3 "$STATE_PY" registry-has "$SCOPE" 2>/dev/null || true)"
REPO_EXISTS=0; gh repo view "$REPO" >/dev/null 2>&1 && REPO_EXISTS=1

# Reuse the registry uuid on a resume; otherwise mint a fresh one.
if [ -n "$REG_HIT" ]; then
  UUID="$(printf '%s' "$REG_HIT" | cut -f1)"
else
  UUID="$(python3 "$STATE_PY" new-uuid)"
fi

# Common fill arguments (only present placeholders get substituted).
fill_args=(
  "uuid=$UUID" "project_name=$NAME" "scope_tag=$SCOPE" "repo=$REPO"
  "bucket=$SCOPE" "created=$CREATED" "protocol_version=$PROTOCOL_VERSION"
  "default_tier=$TIER" "consultants_json=$CONSULTANTS_JSON"
  "founder_handle=$FOUNDER" "tailnet=$TAILNET"
)

print_plan() {
  cat >&2 <<EOF

  Engagement : $NAME
  scope_tag  : $SCOPE
  repo       : $REPO        $([ "$REPO_EXISTS" -eq 1 ] && echo '(EXISTS — resume)' || echo '(will create from template)')
  template   : $TEMPLATE
  uuid       : $UUID        $([ -n "$REG_HIT" ] && echo '(already in registry — resume)' || echo '(new)')
  consultants: $CONSULTANTS_JSON
  tier       : $TIER
  tailnet    : $TAILNET
  registry   : $REG_URL     $([ -n "$REG_HIT" ] && echo '(row present)' || echo '(row will be added)')
  working dir: $TARGET_DIR/$REPO_BASE
EOF
}

if [ "$DRY" -eq 1 ]; then
  printf 'ensemble: DRY RUN — no changes will be made.\n' >&2
  print_plan
  printf '\nensemble: re-run without --dry-run to create the engagement.\n' >&2
  exit 0
fi

printf 'ensemble: standing up engagement %s ...\n' "$NAME" >&2
print_plan

# --- 1) create the repo from the template (create-if-not-exists) -------------
if [ "$REPO_EXISTS" -eq 0 ]; then
  printf 'ensemble: creating %s from template %s ...\n' "$REPO" "$TEMPLATE" >&2
  gh repo create "$REPO" --template "$TEMPLATE" --private >/dev/null \
    || ens_die "could not create the repo $REPO. Check your org permissions and the template."
else
  printf 'ensemble: %s already exists — reusing it.\n' "$REPO" >&2
fi
REPO_REMOTE="$(normalise_remote "$REPO")"

# Template instantiation (gh repo create --template) is ASYNC — the scaffold lands a few
# seconds after the repo exists, so a clone fired too early gets an empty repo. Wait until a
# sentinel template file is visible on the API before cloning.
wait_for_repo_content() {
  local i
  for i in $(seq 1 20); do
    gh api "repos/$REPO/contents/scripts/apply-branch-protection.sh" >/dev/null 2>&1 && return 0
    gh api "repos/$REPO/contents/templates/CLAUDE.md.tmpl" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
printf 'ensemble: waiting for the template scaffold to populate ...\n' >&2
wait_for_repo_content || printf 'ensemble: WARNING — scaffold not visible yet; will re-pull after clone.\n' >&2

# --- 2) clone the working copy + fill placeholders + push main ---------------
REPO_DIR="$TARGET_DIR/$REPO_BASE"
if [ -d "$REPO_DIR/.git" ]; then
  printf 'ensemble: %s already cloned — reusing it.\n' "$REPO_DIR" >&2
  git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1 || true
else
  git clone "$REPO_REMOTE" "$REPO_DIR" >/dev/null 2>&1 \
    || ens_die "could not clone $REPO after creation."
fi

# Guard against an early/empty clone (scaffold still propagating): pull until the sentinel
# template files appear, then assert we actually have the scaffold before proceeding.
if [ ! -f "$REPO_DIR/templates/CLAUDE.md.tmpl" ] && [ ! -f "$REPO_DIR/CLAUDE.md" ]; then
  for _ in 1 2 3 4 5 6 7 8; do
    git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1 || true
    [ -f "$REPO_DIR/templates/CLAUDE.md.tmpl" ] && break
    sleep 2
  done
fi
[ -f "$REPO_DIR/templates/CLAUDE.md.tmpl" ] || [ -f "$REPO_DIR/CLAUDE.md" ] \
  || ens_die "the engagement repo has no template scaffold yet — re-run /init-engagement in a moment (idempotent)."

# Render the root docs from their templates. AGENTS.md is the canonical
# instruction file (AAIF format, read by every coding agent, not only Claude);
# CLAUDE.md is a pointer to it and stays at the root because tether asserts on
# it. Each is rendered only if absent, so a re-run never clobbers an engagement
# that has since edited its own copy.
#
# AGENTS.md.tmpl is guarded rather than assumed: an engagement created from a
# template revision that predates it still has to init cleanly, and in that case
# the old CLAUDE.md.tmpl is the whole process doc rather than a pointer.
if [ ! -f "$REPO_DIR/AGENTS.md" ] && [ -f "$REPO_DIR/templates/AGENTS.md.tmpl" ]; then
  cp "$REPO_DIR/templates/AGENTS.md.tmpl" "$REPO_DIR/AGENTS.md"
fi
if [ ! -f "$REPO_DIR/CLAUDE.md" ] && [ -f "$REPO_DIR/templates/CLAUDE.md.tmpl" ]; then
  cp "$REPO_DIR/templates/CLAUDE.md.tmpl" "$REPO_DIR/CLAUDE.md"
fi

# Fill placeholders only where {{ }} remain (re-run safe).
# .claude/CLAUDE.md is the engagement working-agreement doc shipped by the
# template's .claude/ scaffold; it carries {{project_name}}/{{scope_tag}}/
# {{founder_handle}}/{{tailnet}} which must render at init like the root doc.
for f in AGENTS.md CLAUDE.md .claude/CLAUDE.md .ensemble/project.json .lfsconfig; do
  [ -f "$REPO_DIR/$f" ] || continue
  if grep -q '{{' "$REPO_DIR/$f" 2>/dev/null; then
    python3 "$STATE_PY" fill "$REPO_DIR/$f" "${fill_args[@]}" \
      || ens_die "could not fill placeholders in $f."
  fi
done

if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "chore(init): scaffold $SCOPE engagement (fill template)" >/dev/null
  git -C "$REPO_DIR" push origin HEAD:main >/dev/null 2>&1 \
    || git -C "$REPO_DIR" push >/dev/null 2>&1 \
    || ens_die "could not push the filled scaffold to main."
  printf 'ensemble: scaffold filled and pushed to main.\n' >&2
else
  printf 'ensemble: scaffold already filled — nothing to commit.\n' >&2
fi

# --- 3) apply the two-branch model (idempotent; from the template) -----------
if [ -f "$REPO_DIR/scripts/apply-branch-protection.sh" ]; then
  printf 'ensemble: applying branch model (queue + protected main + tier-gate) ...\n' >&2
  bash "$REPO_DIR/scripts/apply-branch-protection.sh" "$REPO" >&2 \
    || printf 'ensemble: WARNING — branch protection did not fully apply (need admin on %s?). Re-run to complete.\n' "$REPO" >&2
else
  printf 'ensemble: WARNING — scripts/apply-branch-protection.sh not found in the repo; queue/main protection not applied.\n' >&2
fi

# --- 4) register in sasam-registry (idempotent) ------------------------------
refresh_registry
ADD="$(python3 "$STATE_PY" registry-add "$UUID" "$NAME" "$SCOPE" "$REPO")"
if [ "$ADD" = "added" ]; then
  git -C "$REG_DIR" add registry.json
  git -C "$REG_DIR" commit -q -m "chore(registry): add $SCOPE ($NAME)" >/dev/null
  if ! git -C "$REG_DIR" push >/dev/null 2>&1; then
    git -C "$REG_DIR" pull --ff-only >/dev/null 2>&1 || true
    git -C "$REG_DIR" push >/dev/null 2>&1 \
      || ens_die "could not push the registry entry. Re-run to retry (idempotent)."
  fi
  printf 'ensemble: registered %s in the registry.\n' "$SCOPE" >&2
else
  printf 'ensemble: registry already has %s — left as-is.\n' "$SCOPE" >&2
fi

# --- 5) tether to it so /handoff works now -----------------------------------
printf '\n'
printf '════════════════════════════════════════════════════════\n'
printf '  Engagement live: %s\n' "$NAME"
printf '  scope_tag : %s\n' "$SCOPE"
printf '  repo      : https://github.com/%s\n' "$REPO"
printf '  uuid      : %s\n' "$UUID"
printf '  branches  : main (protected, tier-gate) + queue (mailbox)\n'
printf '════════════════════════════════════════════════════════\n'

if [ "$NO_TETHER" -eq 1 ]; then
  printf '\nensemble: skipping tether (--no-tether). Run:  /tether %s   then  /handoff\n' "$SCOPE" >&2
  exit 0
fi
if [ -x "$TETHER_SH" ] || [ -f "$TETHER_SH" ]; then
  printf '\nensemble: tethering to the new engagement ...\n' >&2
  bash "$TETHER_SH" --query "$UUID" --mode clone --dir "$TARGET_DIR" \
    || printf 'ensemble: WARNING — auto-tether did not complete. Run:  /tether %s\n' "$SCOPE" >&2
else
  printf '\nensemble: next:  /tether %s   then  /handoff\n' "$SCOPE" >&2
fi
