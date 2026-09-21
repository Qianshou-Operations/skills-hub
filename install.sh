#!/usr/bin/env bash
#
# install.sh — install the qianshou-* skills into your coding-agent directories.
#
#   ./install.sh                      install into ~/.cursor, ~/.claude, ~/.codex
#   ./install.sh --target ~/.foo      install into a specific agent root (repeatable)
#   ./install.sh --local              install from this checkout instead of GitHub
#   ./install.sh --force              reinstall over an existing copy
#   ./install.sh --ref <git-ref>      pull from another branch/tag (default: main)
#
# For each agent root, e.g. ~/.cursor:
#   root missing          -> the agent isn't installed here, skip it
#   root, no skills/      -> create skills/, then install into it
#   root/skills exists    -> install straight in
#
# Skill files are fetched from raw.githubusercontent.com over HTTPS.

set -euo pipefail

REPO_OWNER="Qianshou-Operations"
REPO_NAME="skills-hub"

DEFAULT_ROOTS=("$HOME/.cursor" "$HOME/.claude" "$HOME/.codex")

# ---------------------------------------------------------------------------
# Skill manifest.
#
# Mirrors the skills/ tree in this repo. Adding a skill (or any file inside
# one) means adding a line here, or the installer will not fetch that file.
# Format: "<skill-dir> <path-relative-to-skill-dir>"
# ---------------------------------------------------------------------------
SKILL_NAMES=(
  qianshou-code-review
  qianshou-i-have-adhd
  qianshou-security-best-practices
)

MANIFEST=(
  "qianshou-code-review SKILL.md"
  "qianshou-code-review agents/openai.yaml"

  "qianshou-i-have-adhd SKILL.md"
  "qianshou-i-have-adhd agents/openai.yaml"
  "qianshou-i-have-adhd agents/gemini.toml"

  "qianshou-security-best-practices SKILL.md"
  "qianshou-security-best-practices LICENSE.txt"
  "qianshou-security-best-practices agents/openai.yaml"
  "qianshou-security-best-practices references/golang-general-backend-security.md"
  "qianshou-security-best-practices references/javascript-express-web-server-security.md"
  "qianshou-security-best-practices references/javascript-general-web-frontend-security.md"
  "qianshou-security-best-practices references/javascript-jquery-web-frontend-security.md"
  "qianshou-security-best-practices references/javascript-typescript-nextjs-web-server-security.md"
  "qianshou-security-best-practices references/javascript-typescript-react-web-frontend-security.md"
  "qianshou-security-best-practices references/javascript-typescript-vue-web-frontend-security.md"
  "qianshou-security-best-practices references/python-django-web-server-security.md"
  "qianshou-security-best-practices references/python-fastapi-web-server-security.md"
  "qianshou-security-best-practices references/python-flask-web-server-security.md"
)

# ---------------------------------------------------------------------------
# Configuration + argument parsing
# ---------------------------------------------------------------------------

ROOTS=("${DEFAULT_ROOTS[@]}")
ROOTS_FROM_FLAG=0
REF="${SKILLS_HUB_REF:-main}"
USE_LOCAL=0
FORCE=0
FAILED=0
INSTALLED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SKILLS="$SCRIPT_DIR/skills"

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok]     %s\n' "$*"; }
skip() { printf '  [skip]   %s\n' "$*"; }
make() { printf '  [create] %s\n' "$*"; }
fail() { printf '  [fail]   %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--target)
      [ $# -ge 2 ] || { say "--target needs a directory" >&2; exit 2; }
      if [ "$ROOTS_FROM_FLAG" -eq 0 ]; then
        ROOTS=("$2")
        ROOTS_FROM_FLAG=1
      else
        ROOTS+=("$2")
      fi
      shift 2
      ;;
    --ref)
      [ $# -ge 2 ] || { say "--ref needs a value" >&2; exit 2; }
      REF="$2"
      shift 2
      ;;
    --local) USE_LOCAL=1; shift ;;
    -f|--force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) say "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REF}/skills"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ---------------------------------------------------------------------------
# Fetch one skill's files into a staging directory
# ---------------------------------------------------------------------------

fetch_skill() {
  local skill="$1"
  local out="$2"
  local entry entry_skill rel

  for entry in "${MANIFEST[@]}"; do
    entry_skill="${entry%% *}"
    rel="${entry#* }"
    [ "$entry_skill" = "$skill" ] || continue

    mkdir -p "$out/$(dirname "$rel")"

    if [ "$USE_LOCAL" -eq 1 ]; then
      if ! cp "$LOCAL_SKILLS/$skill/$rel" "$out/$rel" 2>/dev/null; then
        fail "missing locally: skills/$skill/$rel"
        return 1
      fi
    elif ! curl -fsL "$RAW_BASE/$skill/$rel" -o "$out/$rel"; then
      fail "download failed: $RAW_BASE/$skill/$rel"
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Install one skill into one agent root
# ---------------------------------------------------------------------------

install_skill() {
  local root="$1"
  local skill="$2"
  local dest="$root/skills/$skill"

  if [ -e "$dest" ] && [ "$FORCE" -ne 1 ]; then
    skip "$skill already installed (use --force to overwrite)"
    return 0
  fi

  # Never let a bad value reach the rm -rf below.
  case "$dest" in
    */skills/qianshou-*) ;;
    *) fail "refusing to write to unexpected path: $dest"; return 1 ;;
  esac

  if ! fetch_skill "$skill" "$STAGE/$skill"; then
    return 1
  fi

  # Only touch the destination once every file is staged.
  rm -rf "$dest"
  mv "$STAGE/$skill" "$dest"
  ok "$skill"
  INSTALLED=$((INSTALLED + 1))
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$USE_LOCAL" -eq 1 ]; then
  [ -d "$LOCAL_SKILLS" ] || { fail "no skills/ directory next to this script"; exit 1; }
  say "Source: $LOCAL_SKILLS"
else
  command -v curl >/dev/null 2>&1 || { fail "curl is required"; exit 1; }
  say "Source: $RAW_BASE"
fi
say "Skills: ${SKILL_NAMES[*]}"
say ""

for root in "${ROOTS[@]}"; do
  # Tolerate a trailing slash so `--target ~/.claude/` still prints cleanly.
  root="${root%/}"
  say "$root"

  if [ ! -d "$root" ]; then
    skip "agent root does not exist, skipping"
    say ""
    continue
  fi

  if [ ! -d "$root/skills" ]; then
    if mkdir -p "$root/skills"; then
      make "skills/"
    else
      fail "could not create $root/skills"
      FAILED=$((FAILED + 1))
      say ""
      continue
    fi
  fi

  for skill in "${SKILL_NAMES[@]}"; do
    if ! install_skill "$root" "$skill"; then
      FAILED=$((FAILED + 1))
    fi
  done
  say ""
done

if [ "$FAILED" -gt 0 ]; then
  fail "$FAILED skill(s) failed; $INSTALLED installed"
  if [ "$USE_LOCAL" -eq 0 ]; then
    fail "if the URLs above 404, branch '$REF' may not exist yet — try --ref <branch>"
  fi
  exit 1
fi

say "Done. Installed $INSTALLED skill(s)."
