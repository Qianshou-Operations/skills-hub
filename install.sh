#!/usr/bin/env bash
#
# install.sh — install, verify and remove the qianshou-* skills.
#
#   curl -fsSL https://raw.githubusercontent.com/Qianshou-Operations/skills-hub/main/install.sh | bash
#
# Targets default to ~/.cursor/skills, ~/.claude/skills and ~/.codex/skills.
# An agent root that does not exist is skipped; a root without a skills/
# subdirectory gets one created. Existing skills are never overwritten
# unless --force is given, and --force backs the old copy up first.
#
# Requires bash 3.2+ (the version macOS ships) and curl. Deliberately avoids
# mapfile, associative arrays, ${var,,} and namerefs so it runs unmodified
# on a stock macOS shell.

set -euo pipefail

# ===========================================================================
# Constants
# ===========================================================================

REPO_OWNER="Qianshou-Operations"
REPO_NAME="skills-hub"

DEFAULT_ROOTS=("$HOME/.cursor" "$HOME/.claude" "$HOME/.codex")

STAMP_NAME=".qianshou-skills.stamp"
BACKUP_DIR=".qianshou-backups"

DEFAULT_JOBS=4
DEFAULT_RETRIES=3
DEFAULT_RETRY_DELAY=2
CONNECT_TIMEOUT=10
MAX_TIME=120

# ---------------------------------------------------------------------------
# Skill manifest.
#
# Mirrors the skills/ tree in this repo. Adding a skill, or any file inside
# one, means adding a line here — the installer downloads exactly these
# paths and nothing else. Format: "<skill-dir> <path-relative-to-skill-dir>"
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

# ===========================================================================
# Colour
#
# Off when stdout is not a terminal, when NO_COLOR is set, or on a dumb
# terminal. Under `curl ... | bash` stdout is still the terminal, so colour
# survives the pipe.
# ===========================================================================

setup_colour() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    esc=$(printf '\033')
    C_RESET="${esc}[0m"
    C_DIM="${esc}[2m"
    C_BOLD="${esc}[1m"
    C_RED="${esc}[31m"
    C_GREEN="${esc}[32m"
    C_YELLOW="${esc}[33m"
    C_CYAN="${esc}[36m"
  else
    C_RESET=""
    C_DIM=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
  fi
}

# ===========================================================================
# Logging
#
# Verbosity: quiet (warn/fail only) < normal < verbose (+ every download).
# dry-run prints what would happen and performs no writes.
# ===========================================================================

VERBOSE=0
QUIET=0
DRY_RUN=0

emit() {
  # emit <colour> <label> <message...>
  local colour="$1"
  local label="$2"
  shift 2
  printf '  %s%-8s%s %s\n' "$colour" "$label" "$C_RESET" "$*"
}

log_ok()   { [ "$QUIET" -eq 1 ] && return 0; emit "$C_GREEN" "[ok]" "$@"; }
log_skip() { [ "$QUIET" -eq 1 ] && return 0; emit "$C_DIM" "[skip]" "$@"; }
log_make() { [ "$QUIET" -eq 1 ] && return 0; emit "$C_CYAN" "[create]" "$@"; }
log_move() { [ "$QUIET" -eq 1 ] && return 0; emit "$C_YELLOW" "[backup]" "$@"; }
log_rm()   { [ "$QUIET" -eq 1 ] && return 0; emit "$C_YELLOW" "[remove]" "$@"; }
log_warn() { emit "$C_YELLOW" "[warn]" "$@"; }
log_fail() { emit "$C_RED" "[fail]" "$@" >&2; }
log_dry()  { [ "$QUIET" -eq 1 ] && return 0; emit "$C_CYAN" "[dry-run]" "$@"; }

say()     { [ "$QUIET" -eq 1 ] && return 0; printf '%s\n' "$@"; }
say_raw() { printf '%s\n' "$@"; }
heading() { [ "$QUIET" -eq 1 ] && return 0; printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# ===========================================================================
# Usage
#
# Inlined rather than read from "$0": under `curl ... | bash` there is no
# script file on disk for $0 to point at.
# ===========================================================================

usage() {
  cat <<'USAGE'
install.sh — install, verify and remove the qianshou-* skills.

Usage:
  install.sh [options]

Modes (default is install):
  (none)                install every skill into every target root
  --list                list the skills this installer knows about
  --verify              check installed skills against the recorded digests
  --uninstall           remove the skills from every target root

Options:
  -t, --target DIR      agent root to act on; repeatable
                        (default: ~/.cursor ~/.claude ~/.codex)
      --ref REF         git branch or tag to fetch from (default: main)
      --local           install from ./skills instead of GitHub
      --force           overwrite existing skills
      --no-backup       with --force, delete the old copy instead of backing it up
      --dry-run         show what would happen, change nothing
  -j, --jobs N          parallel downloads (default: 4)
      --retries N       download attempts per file (default: 3)
      --timeout N       connect timeout in seconds (default: 10)
  -q, --quiet           warnings and errors only
  -v, --verbose         also log every downloaded file
  -h, --help            this message

Target-directory behaviour, per agent root (e.g. ~/.cursor):
  root missing          the agent is not installed here — skipped entirely
  root, no skills/      skills/ is created, then the skills are installed
  root/skills exists    the skills are installed straight in
  skill already present left alone; --force is required to replace it

Files are fetched from raw.githubusercontent.com over HTTPS, staged in a
temporary directory, and moved into place only once every file for that
skill has downloaded and validated. A failed download leaves nothing behind.

Environment:
  SKILLS_HUB_REF        same as --ref
  NO_COLOR              disable coloured output
USAGE
}

# ===========================================================================
# Argument parsing
# ===========================================================================

ROOTS=("${DEFAULT_ROOTS[@]}")
ROOTS_FROM_FLAG=0
REF="${SKILLS_HUB_REF:-main}"
USE_LOCAL=0
FORCE=0
BACKUP=1
JOBS="$DEFAULT_JOBS"
RETRIES="$DEFAULT_RETRIES"
MODE="install"

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -t|--target)
        [ $# -ge 2 ] || { say_raw "error: --target needs a directory" >&2; exit 2; }
        if [ "$ROOTS_FROM_FLAG" -eq 0 ]; then
          ROOTS=("$2")
          ROOTS_FROM_FLAG=1
        else
          ROOTS[${#ROOTS[@]}]="$2"
        fi
        shift 2
        ;;
      --ref)
        [ $# -ge 2 ] || { say_raw "error: --ref needs a value" >&2; exit 2; }
        REF="$2"
        shift 2
        ;;
      -j|--jobs)
        [ $# -ge 2 ] || { say_raw "error: --jobs needs a number" >&2; exit 2; }
        JOBS="$2"
        shift 2
        ;;
      --retries)
        [ $# -ge 2 ] || { say_raw "error: --retries needs a number" >&2; exit 2; }
        RETRIES="$2"
        shift 2
        ;;
      --timeout)
        [ $# -ge 2 ] || { say_raw "error: --timeout needs a number" >&2; exit 2; }
        CONNECT_TIMEOUT="$2"
        shift 2
        ;;
      --list)      MODE="list"; shift ;;
      --verify)    MODE="verify"; shift ;;
      --uninstall) MODE="uninstall"; shift ;;
      --local)     USE_LOCAL=1; shift ;;
      --force)     FORCE=1; shift ;;
      --no-backup) BACKUP=0; shift ;;
      --dry-run)   DRY_RUN=1; shift ;;
      -q|--quiet)  QUIET=1; shift ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) say_raw "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  case "$JOBS" in
    ''|*[!0-9]*) say_raw "error: --jobs must be a positive integer" >&2; exit 2 ;;
  esac
  [ "$JOBS" -ge 1 ] || { say_raw "error: --jobs must be at least 1" >&2; exit 2; }

  case "$RETRIES" in
    ''|*[!0-9]*) say_raw "error: --retries must be a positive integer" >&2; exit 2 ;;
  esac
  [ "$RETRIES" -ge 1 ] || { say_raw "error: --retries must be at least 1" >&2; exit 2; }
}

# ===========================================================================
# Small helpers
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)"
LOCAL_SKILLS="$SCRIPT_DIR/skills"

RAW_BASE=""

STAGE=""
RESULTS=""
CLEANUP_DONE=0

cleanup() {
  [ "$CLEANUP_DONE" -eq 1 ] && return 0
  CLEANUP_DONE=1
  [ -n "$STAGE" ] && [ -d "$STAGE" ] && rm -rf "$STAGE"
  [ -n "$RESULTS" ] && [ -d "$RESULTS" ] && rm -rf "$RESULTS"
  return 0
}

trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT TERM

timestamp() { date '+%Y%m%d-%H%M%S'; }

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1 "-" $2}'
  fi
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    cksum "$1" | awk '{print $1 "-" $2}'
  fi
}

# Digest of every file a skill is supposed to contain. Returns
# "missing:<path>" instead of a digest when a file is absent, so a truncated
# install can never compare equal to a good one.
skill_digest() {
  local dir="$1"
  local skill="$2"
  local entry entry_skill rel acc=""

  for entry in "${MANIFEST[@]}"; do
    entry_skill="${entry%% *}"
    rel="${entry#* }"
    [ "$entry_skill" = "$skill" ] || continue
    [ -f "$dir/$rel" ] || { printf 'missing:%s' "$rel"; return 0; }
    acc="${acc}$(hash_file "$dir/$rel")  ${rel}"$'\n'
  done

  printf '%s' "$acc" | hash_stdin
}

# Read the `name:` field out of a SKILL.md frontmatter block.
fm_name() {
  local raw
  raw="$(awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { inblock = 1; next }
    inblock && $0 == "---" { exit }
    inblock && /^name:[ \t]*/ {
      sub(/^name:[ \t]*/, "")
      sub(/[ \t]+$/, "")
      print
      exit
    }
  ' "$1")"

  # Strip one layer of matching quotes.
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac

  printf '%s' "$raw"
}

files_for_skill() {
  local skill="$1"
  local entry entry_skill count=0
  for entry in "${MANIFEST[@]}"; do
    entry_skill="${entry%% *}"
    [ "$entry_skill" = "$skill" ] && count=$((count + 1))
  done
  printf '%s' "$count"
}

# ===========================================================================
# Preflight
# ===========================================================================

preflight() {
  local missing=0

  if [ "$USE_LOCAL" -eq 1 ]; then
    if [ ! -d "$LOCAL_SKILLS" ]; then
      log_fail "--local needs a skills/ directory next to this script"
      log_fail "looked in: $LOCAL_SKILLS"
      return 1
    fi
  else
    if ! command -v curl >/dev/null 2>&1; then
      log_fail "curl is required but was not found on PATH"
      missing=1
    fi
  fi

  if ! command -v shasum >/dev/null 2>&1 \
     && ! command -v sha256sum >/dev/null 2>&1 \
     && ! command -v cksum >/dev/null 2>&1; then
    log_fail "need one of shasum, sha256sum or cksum for integrity checking"
    missing=1
  fi

  [ "$missing" -eq 0 ]
}

# ===========================================================================
# Download engine
#
# Files are fetched up to --jobs at a time. Each worker records ok/fail in
# its own status file rather than exporting a variable, because it runs in a
# subshell; the parent collects the results after each wait.
# ===========================================================================

# download_one <url> <out> <status-file>
download_one() {
  local url="$1"
  local out="$2"
  local status="$3"
  local attempt=1
  local delay="$DEFAULT_RETRY_DELAY"

  while : ; do
    if curl -fsL \
         --connect-timeout "$CONNECT_TIMEOUT" \
         --max-time "$MAX_TIME" \
         "$url" -o "$out" 2>/dev/null; then
      # A 200 with an empty body is still a broken install.
      if [ -s "$out" ]; then
        printf 'ok %s' "$attempt" > "$status"
        return 0
      fi
    fi

    if [ "$attempt" -ge "$RETRIES" ]; then
      printf 'fail %s' "$attempt" > "$status"
      [ -f "$out" ] && rm -f "$out"
      return 1
    fi

    printf 'retry %s' "$attempt" > "$status"
    [ "$VERBOSE" -eq 1 ] && printf '      %sretry %s/%s in %ss: %s%s\n' \
      "$C_YELLOW" "$attempt" "$RETRIES" "$delay" "$url" "$C_RESET" >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# Copy one file from the local checkout, for --local.
copy_one() {
  local src="$1"
  local out="$2"
  local status="$3"

  if [ -f "$src" ]; then
    if cp "$src" "$out" 2>/dev/null && [ -s "$out" ]; then
      printf 'ok 1' > "$status"
      return 0
    fi
  fi
  printf 'fail 1' > "$status"
  return 1
}

# Fetch every manifest file for every skill into <stage>/<skill>/...
# Returns 0 only if all of them succeeded.
download_all() {
  local stage="$1"
  local entry entry_skill rel out url idx=0
  local pids=() labels=() statuses=()
  local head=0 done_count=0 failed_count=0 total
  local in_flight status_file label

  total=$(files_for_skill_total)
  mkdir -p "$RESULTS"

  for entry in "${MANIFEST[@]}"; do
    entry_skill="${entry%% *}"
    rel="${entry#* }"
    idx=$((idx + 1))

    out="$stage/$entry_skill/$rel"
    mkdir -p "$(dirname "$out")"
    status_file="$RESULTS/$idx.status"

    label="$entry_skill/$rel"
    if [ "$USE_LOCAL" -eq 1 ]; then
      copy_one "$LOCAL_SKILLS/$entry_skill/$rel" "$out" "$status_file" &
    else
      url="$RAW_BASE/$entry_skill/$rel"
      download_one "$url" "$out" "$status_file" &
    fi

    pids[${#pids[@]}]=$!
    labels[${#labels[@]}]="$label"
    statuses[${#statuses[@]}]="$status_file"

    # Keep at most $JOBS workers alive: wait for the oldest when full.
    while [ $(( ${#pids[@]} - head )) -ge "$JOBS" ]; do
      status_file="${statuses[$head]}"
      if wait "${pids[$head]}"; then
        done_count=$((done_count + 1))
      else
        done_count=$((done_count + 1))
        failed_count=$((failed_count + 1))
        log_fail "download failed: ${labels[$head]}"
      fi
      [ "$VERBOSE" -eq 1 ] && progress_line "$done_count" "$total" "${labels[$head]}"
      head=$((head + 1))
    done
  done

  # Drain whatever is still in flight.
  while [ "$head" -lt "${#pids[@]}" ]; do
    status_file="${statuses[$head]}"
    if wait "${pids[$head]}"; then
      done_count=$((done_count + 1))
    else
      done_count=$((done_count + 1))
      failed_count=$((failed_count + 1))
      log_fail "download failed: ${labels[$head]}"
    fi
    [ "$VERBOSE" -eq 1 ] && progress_line "$done_count" "$total" "${labels[$head]}"
    head=$((head + 1))
  done

  [ "$failed_count" -eq 0 ]
}

files_for_skill_total() {
  local total=0
  for rel in "${SKILL_NAMES[@]}"; do
    total=$((total + $(files_for_skill "$rel")))
  done
  printf '%s' "$total"
}

progress_line() {
  printf '  %s[%s/%s]%s %s\n' "$C_DIM" "$1" "$2" "$C_RESET" "$3"
}

# ===========================================================================
# Validation
# ===========================================================================

# Confirm a staged skill is complete and internally consistent.
# Validates only staged copies — never the user's installed tree.
validate_skill() {
  local dir="$1"
  local skill="$2"
  local entry entry_skill rel problem=0
  local declared

  for entry in "${MANIFEST[@]}"; do
    entry_skill="${entry%% *}"
    rel="${entry#* }"
    [ "$entry_skill" = "$skill" ] || continue
    if [ ! -s "$dir/$rel" ]; then
      log_fail "$skill: missing or empty after download: $rel"
      problem=1
    fi
  done

  if [ ! -f "$dir/SKILL.md" ]; then
    return 1
  fi

  # The frontmatter name must match the directory, or the agent will
  # register the skill under a name the installer never promised.
  declared="$(fm_name "$dir/SKILL.md")"
  if [ -z "$declared" ]; then
    log_warn "$skill: SKILL.md has no name: field in its frontmatter"
  elif [ "$declared" != "$skill" ]; then
    log_warn "$skill: frontmatter name is \"$declared\", directory is \"$skill\""
  fi

  [ "$problem" -eq 0 ]
}

# ===========================================================================
# Stamp file
#
# One line per installed skill, so --verify and --uninstall know what this
# installer put there without guessing from the directory listing.
#   <skill> <ref> <digest> <installed-at>
# ===========================================================================

stamp_path() { printf '%s/skills/%s' "$1" "$STAMP_NAME"; }

stamp_read() {
  local file="$1"
  [ -f "$file" ] && cat "$file" || true
}

stamp_digest_of() {
  local file="$1"
  local skill="$2"
  [ -f "$file" ] || return 0
  awk -v s="$skill" '$1 == s { print $3; exit }' "$file"
}

stamp_write_entry() {
  local root="$1"
  local skill="$2"
  local digest="$3"
  local file
  file="$(stamp_path "$root")"
  local tmp="$file.tmp.$$"

  # Drop any previous line for this skill, then append the new one.
  if [ -f "$file" ]; then
    awk -v s="$skill" '$1 != s' "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s %s %s %s\n' "$skill" "$REF" "$digest" "$(timestamp)" >> "$tmp"
  mv "$tmp" "$file"
}

stamp_drop_entry() {
  local root="$1"
  local skill="$2"
  local file tmp
  file="$(stamp_path "$root")"
  [ -f "$file" ] || return 0
  tmp="$file.tmp.$$"
  awk -v s="$skill" '$1 != s' "$file" > "$tmp"
  if [ -s "$tmp" ]; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp" "$file"
  fi
}

# ===========================================================================
# Install
# ===========================================================================

install_skill() {
  local root="$1"
  local skill="$2"
  local dest="$root/skills/$skill"
  local staged="$STAGE/$skill"
  local digest

  if [ -e "$dest" ] && [ "$FORCE" -eq 0 ]; then
    log_skip "$skill already installed (--force to replace)"
    LAST_ACTION="skipped"
    return 0
  fi

  # Never let a bad value reach the rm/backup calls below.
  case "$dest" in
    */skills/qianshou-*) ;;
    *) log_fail "refusing to write to unexpected path: $dest"; return 1 ;;
  esac

  if [ ! -d "$staged" ]; then
    log_fail "$skill: nothing staged"
    return 1
  fi

  digest="$(skill_digest "$staged" "$skill")"

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -e "$dest" ]; then
      log_dry "would back up and replace $dest"
    else
      log_dry "would install $skill to $dest"
    fi
    LAST_ACTION="installed"
    return 0
  fi

  # Back the old copy up rather than deleting it outright.
  if [ -e "$dest" ]; then
    if [ "$BACKUP" -eq 1 ]; then
      # BACKUP_TS is stamped once per root, so every skill replaced in this
      # run lands in the same backup directory.
      local backup="$root/skills/$BACKUP_DIR/$BACKUP_TS"
      if mkdir -p "$backup" && mv "$dest" "$backup/$skill"; then
        log_move "$skill -> skills/$BACKUP_DIR/$BACKUP_TS/$skill"
      else
        log_fail "$skill: could not back up $dest"
        return 1
      fi
    else
      rm -rf "$dest"
    fi
  fi

  mkdir -p "$root/skills"

  # Copy rather than move: the staged tree is shared by every target root.
  # Land it on a hidden sibling first so the destination is never half-written.
  local incoming="$root/skills/.incoming-$$"
  rm -rf "$incoming"
  if ! cp -R "$staged" "$incoming"; then
    rm -rf "$incoming"
    log_fail "$skill: could not copy staged files into place"
    return 1
  fi
  mv "$incoming" "$dest"

  stamp_write_entry "$root" "$skill" "$digest"
  LAST_ACTION="installed"
  log_ok "$skill"
  return 0
}

do_install_root() {
  local root="$1"
  local installed=0

  root="${root%/}"
  BACKUP_TS="$(timestamp)"

  say ""
  heading "$root"

  if [ ! -d "$root" ]; then
    log_skip "agent root does not exist — this agent is not installed here"
    return 0
  fi

  if [ ! -d "$root/skills" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "would create $root/skills"
    elif ! mkdir -p "$root/skills"; then
      log_fail "could not create $root/skills"
      FAILED=$((FAILED + 1))
      return 1
    else
      log_make "skills/"
    fi
  fi

  for skill in "${SKILL_NAMES[@]}"; do
    LAST_ACTION=""
    if install_skill "$root" "$skill"; then
      case "$LAST_ACTION" in
        installed) INSTALLED=$((INSTALLED + 1)) ;;
        *)         SKIPPED=$((SKIPPED + 1)) ;;
      esac
    else
      FAILED=$((FAILED + 1))
    fi
  done

  return 0
}

# ===========================================================================
# Verify
# ===========================================================================

verify_root() {
  local root="$1"
  local file
  root="${root%/}"
  file="$(stamp_path "$root")"

  say ""
  heading "$root"

  if [ ! -d "$root/skills" ]; then
    log_skip "no skills/ directory"
    return 0
  fi

  for skill in "${SKILL_NAMES[@]}"; do
    local dir="$root/skills/$skill"
    if [ ! -d "$dir" ]; then
      log_skip "$skill not installed"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    local expected recorded actual
    expected="$(stamp_digest_of "$file" "$skill")"
    actual="$(skill_digest "$dir" "$skill")"

    if [ -z "$expected" ]; then
      log_warn "$skill installed but not recorded in the stamp file"
      WARNED=$((WARNED + 1))
      continue
    fi

    recorded="$(awk -v s="$skill" '$1 == s { print $2 }' "$file")"

    if [ "$actual" = "$expected" ]; then
      log_ok "$skill matches its ${recorded:-unknown} install"
      VERIFIED=$((VERIFIED + 1))
    else
      case "$actual" in
        missing:*)
          log_fail "$skill is incomplete — ${actual#missing:} is gone"
          ;;
        *)
          log_warn "$skill has local modifications (digest differs)"
          ;;
      esac
      FAILED=$((FAILED + 1))
    fi
  done

  return 0
}

# ===========================================================================
# Uninstall
# ===========================================================================

uninstall_root() {
  local root="$1"
  root="${root%/}"

  say ""
  heading "$root"

  if [ ! -d "$root/skills" ]; then
    log_skip "no skills/ directory"
    return 0
  fi

  for skill in "${SKILL_NAMES[@]}"; do
    local dir="$root/skills/$skill"

    case "$dir" in
      */skills/qianshou-*) ;;
      *) log_fail "refusing to remove unexpected path: $dir"; FAILED=$((FAILED + 1)); continue ;;
    esac

    if [ ! -d "$dir" ]; then
      log_skip "$skill not installed"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "would remove $dir"
      REMOVED=$((REMOVED + 1))
      continue
    fi

    if rm -rf "$dir"; then
      stamp_drop_entry "$root" "$skill"
      log_rm "$skill"
      REMOVED=$((REMOVED + 1))
    else
      log_fail "could not remove $dir"
      FAILED=$((FAILED + 1))
    fi
  done

  # Tidy up dirs we own, if they are now empty. Note that a bare
  # `test && test && rm` would leave this function returning 1 when the
  # stamp file is already gone, which `set -e` turns into a hard abort.
  if [ "$DRY_RUN" -eq 0 ]; then
    rmdir "$root/skills/$BACKUP_DIR"/* 2>/dev/null || true
    rmdir "$root/skills/$BACKUP_DIR" 2>/dev/null || true
    if [ -f "$(stamp_path "$root")" ] && [ ! -s "$(stamp_path "$root")" ]; then
      rm -f "$(stamp_path "$root")"
    fi
  fi

  return 0
}

# ===========================================================================
# List
# ===========================================================================

do_list() {
  local skill count desc
  say "Available skills in $REPO_OWNER/$REPO_NAME:"
  say ""
  for skill in "${SKILL_NAMES[@]}"; do
    count="$(files_for_skill "$skill")"
    desc=""
    if [ -f "$LOCAL_SKILLS/$skill/SKILL.md" ]; then
      desc="$(fm_name "$LOCAL_SKILLS/$skill/SKILL.md" 2>/dev/null || true)"
    fi
    printf '  %s%-34s%s %s file(s)\n' "$C_CYAN" "$skill" "$C_RESET" "$count"
  done
  say ""
  say "Install with: install.sh [--target DIR ...]"
}

# ===========================================================================
# Main
# ===========================================================================

INSTALLED=0
SKIPPED=0
FAILED=0
REMOVED=0
VERIFIED=0
WARNED=0

# Set by install_skill so the caller can tell an install from a skip.
LAST_ACTION=""

# One backup directory per target root per run, so --force does not spray
# timestamped directories across the filesystem.
BACKUP_TS=""

main() {
  setup_colour
  parse_args "$@"

  case "$MODE" in
    list) do_list; return 0 ;;
  esac

  RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REF}/skills"

  say ""
  if [ "$USE_LOCAL" -eq 1 ]; then
    say "Source: $LOCAL_SKILLS"
  else
    say "Source: $RAW_BASE"
  fi
  say "Mode:   $MODE$([ "$DRY_RUN" -eq 1 ] && printf ' (dry run)')"

  if ! preflight; then
    say ""
    return 1
  fi

  case "$MODE" in
    verify)
      for root in "${ROOTS[@]}"; do
        verify_root "$root"
      done
      summary
      if [ "$FAILED" -gt 0 ]; then return 1; fi
      return 0
      ;;
    uninstall)
      for root in "${ROOTS[@]}"; do
        uninstall_root "$root"
      done
      summary
      if [ "$FAILED" -gt 0 ]; then return 1; fi
      return 0
      ;;
  esac

  # install
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/qianshou-skills.XXXXXX")"
  RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/qianshou-results.XXXXXX")"

  say ""
  heading "Downloading"
  if ! download_all "$STAGE"; then
    log_fail "one or more files could not be downloaded — nothing was installed"
    if [ "$USE_LOCAL" -eq 0 ]; then
      log_fail "if the URLs above 404, branch '$REF' may not exist — try --ref <branch>"
    fi
    FAILED="${#SKILL_NAMES[@]}"
    summary
    return 1
  fi
  say "  $(files_for_skill_total) file(s) ready"

  # Validate the staged tree once, before touching any target root, so a bad
  # download can never be installed into some agents and not others.
  for skill in "${SKILL_NAMES[@]}"; do
    if ! validate_skill "$STAGE/$skill" "$skill"; then
      log_fail "$skill failed validation — nothing was installed"
      FAILED="${#SKILL_NAMES[@]}"
      summary
      return 1
    fi
  done

  for root in "${ROOTS[@]}"; do
    do_install_root "$root"
  done

  summary
  if [ "$FAILED" -gt 0 ]; then return 1; fi
  return 0
}

summary() {
  local parts=""

  # --quiet means warnings and errors only; the counts are neither. The
  # individual [fail] lines still reach stderr through log_fail.
  [ "$QUIET" -eq 1 ] && return 0

  say ""

  case "$MODE" in
    uninstall) parts="removed $REMOVED   " ;;
    verify)    parts="verified $VERIFIED   " ;;
    *)         parts="installed $INSTALLED   " ;;
  esac
  parts="${parts}skipped $SKIPPED"
  [ "$WARNED" -gt 0 ] && parts="${parts}   warned $WARNED"
  parts="${parts}   failed $FAILED"

  heading "Summary"
  if [ "$FAILED" -gt 0 ]; then
    printf '  %s%s%s\n' "$C_RED" "$parts" "$C_RESET"
  else
    printf '  %s%s%s\n' "$C_GREEN" "$parts" "$C_RESET"
  fi

  if [ "$MODE" = "install" ] && [ "$FAILED" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    [ "$INSTALLED" -gt 0 ] && printf '  Skills are live in the target agent(s).\n'
  fi
  say ""
}

main "$@"
