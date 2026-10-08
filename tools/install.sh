#!/usr/bin/env bash
# install.sh — install or update the tools in this folder. Requires bash 4.4+.
set -euo pipefail

TOOLS=(tm gls)
# tool:command:note — commands a tool needs at run time, reported when missing
DEPS=(
  "tm:tmux:"
  "tm:jq:only for 'tm claude'"
  "gls:git:"
)
SYSTEM_DIR="/usr/local/bin"

MODE="link"    # link | copy
BIN_DIR=""
CHECK=0
SUDO=()
RC=0

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

die()  { printf 'install: %s\n' "$*" >&2; exit 1; }
info() { printf 'install: %s\n' "$*" >&2; }
report() { printf '%-4s %-14s %s\n' "$1" "$2" "$3"; }

# Is this file one of ours? Judged by the header comment every tool carries on
# its second line, so an unrelated program that shares the name is never
# overwritten.
is_ours() {
  local file="$1" tool="$2" line=""
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then return 1; fi
  { read -r line && read -r line; } <"$file" 2>/dev/null || return 1
  case "$line" in
    "# $tool — "*) return 0 ;;
  esac
  return 1
}

# What is at the destination right now:
#   missing    nothing
#   link       symlink to this folder's file
#   dangling   symlink to nothing
#   otherlink  symlink to another copy of the tool
#   same       regular file, identical to this folder's
#   differs    regular file, some other version of the tool
#   foreign    anything that is not the tool
classify() {
  local tool="$1" src="$2" dest="$3"
  if [ -L "$dest" ]; then
    if [ ! -e "$dest" ]; then
      echo dangling
    elif [ "$(readlink -f -- "$dest")" = "$src" ]; then
      echo link
    elif is_ours "$dest" "$tool"; then
      echo otherlink
    else
      echo foreign
    fi
  elif [ ! -e "$dest" ]; then
    echo missing
  elif ! is_ours "$dest" "$tool"; then
    echo foreign
  elif cmp -s -- "$src" "$dest"; then
    echo same
  else
    echo differs
  fi
}

# Writes into BIN_DIR go through SUDO when the directory is not ours, so a
# system directory costs one sudo prompt instead of running everything as root.
# Called only once something actually has to be written.
use_sudo() {
  if [ ${#SUDO[@]} -gt 0 ]; then return 0; fi
  if [ "$(id -u)" -eq 0 ]; then die "cannot write to $BIN_DIR"; fi
  command -v sudo >/dev/null 2>&1 || die "cannot write to $BIN_DIR, and sudo is not available"
  info "$BIN_DIR is not writable by you; using sudo"
  SUDO=(sudo)
}

DIR_READY=0
prepare_dir() {
  if [ "$DIR_READY" -eq 1 ]; then return 0; fi
  if [ ! -d "$BIN_DIR" ] && ! mkdir -p -- "$BIN_DIR" 2>/dev/null; then
    use_sudo
    "${SUDO[@]}" mkdir -p -- "$BIN_DIR"
  fi
  if [ ! -w "$BIN_DIR" ]; then use_sudo; fi
  DIR_READY=1
}

put_link() {
  ${SUDO[@]+"${SUDO[@]}"} ln -sfn -- "$1" "$2"
}

# Copy to a temp name and rename over the destination: writing to the
# destination directly would follow an existing symlink and overwrite the
# source file it points at.
put_copy() {
  local tmp="$2.tmp.$$"
  if ! ${SUDO[@]+"${SUDO[@]}"} install -m 0755 -- "$1" "$tmp" \
     || ! ${SUDO[@]+"${SUDO[@]}"} mv -f -- "$tmp" "$2"; then
    ${SUDO[@]+"${SUDO[@]}"} rm -f -- "$tmp" 2>/dev/null || true
    die "could not write $2"
  fi
}

process() {
  local tool="$1" src dest state want was="" wanted="" detail
  src="$(readlink -f -- "$HERE/$tool")"
  dest="$BIN_DIR/$tool"
  [ -f "$src" ] || die "missing tool: $HERE/$tool"
  [ -x "$src" ] || die "not executable: $src"

  state="$(classify "$tool" "$src" "$dest")"
  if [ "$MODE" = link ]; then
    want="link"
    detail="$dest -> $src"
  else
    want="same"
    detail="$dest (copy)"
  fi

  case "$state" in
    "$want")
      report "$tool" "up to date" "$detail"
      return 0
      ;;
    foreign)
      report "$tool" "skipped" "$dest exists and is not $tool from this folder; remove it to install here"
      RC=1
      return 0
      ;;
    missing)   ;;
    dangling)  was="dangling symlink" ;;
    otherlink) was="symlink to $(readlink -f -- "$dest")" ;;
    differs)   was="copy that differs from $src" ;;
    same)      was="copy"; wanted=", symlink wanted" ;;
    link)      was="symlink"; wanted=", copy wanted" ;;
  esac

  if [ "$CHECK" -eq 1 ]; then
    if [ "$state" = missing ]; then
      report "$tool" "not installed" "$dest"
    else
      report "$tool" "out of date" "$dest ($was$wanted)"
    fi
    RC=1
    return 0
  fi

  prepare_dir
  if [ "$MODE" = link ]; then put_link "$src" "$dest"; else put_copy "$src" "$dest"; fi
  if [ "$state" = missing ]; then
    report "$tool" "installed" "$detail"
  else
    report "$tool" "updated" "$detail; was a $was"
  fi
}

# The first executable called $1 on PATH, the way a shell would find it.
first_on_path() {
  local -a dirs=()
  local d
  IFS=: read -r -a dirs <<<"$PATH"
  for d in ${dirs[@]+"${dirs[@]}"}; do
    if [ -n "$d" ] && [ -f "$d/$1" ] && [ -x "$d/$1" ]; then
      printf '%s\n' "$d/$1"
      return 0
    fi
  done
  return 0
}

path_notes() {
  local tool first
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      info "note: $BIN_DIR is not on your PATH; add it to run the tools by name"
      return 0
      ;;
  esac
  for tool in "${TOOLS[@]}"; do
    if [ ! -e "$BIN_DIR/$tool" ]; then continue; fi
    first="$(first_on_path "$tool")"
    if [ -n "$first" ] && [ "$first" != "$BIN_DIR/$tool" ]; then
      info "note: '$tool' runs $first, which comes before $BIN_DIR on your PATH"
    fi
  done
}

dep_notes() {
  local dep tool cmd note
  for dep in "${DEPS[@]}"; do
    IFS=: read -r tool cmd note <<<"$dep"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      info "note: $tool needs $cmd${note:+ ($note)}, which is not installed"
    fi
  done
}

cmd_help() {
  cat <<EOF
install.sh — install or update the tools in this folder (${TOOLS[*]})

Usage:
  ./install.sh [options]

Options:
  (none)       Install as symlinks in ~/.local/bin
  --copy       Install standalone copies instead of symlinks
  --system     Install into $SYSTEM_DIR (uses sudo for the writes if needed)
  --dir DIR    Install into DIR
  --check      Report only and change nothing; exit 1 unless everything is
               installed and up to date
  -h, --help   Show this help

Run it again at any time: each tool is reported as "up to date", "installed",
"updated" or "skipped", and only what needs changing is touched.

A symlink always runs the file in this folder, so it is out of date only when
it is missing, dangling or points elsewhere. A copy is compared byte for byte
with the file in this folder and replaced when they differ. Switching between
the two modes converts what is installed.

A file that is in the way and is not one of these tools is never overwritten:
that tool is skipped and the exit status is 1.
EOF
}

parse_args() {
  local system=0 dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --copy)    MODE=copy ;;
      --system)  system=1 ;;
      --check)   CHECK=1 ;;
      --dir)
        if [ $# -lt 2 ] || [ -z "$2" ]; then die "--dir needs a directory"; fi
        dir="$2"
        shift
        ;;
      --dir=?*)  dir="${1#--dir=}" ;;
      -h|--help) cmd_help; exit 0 ;;
      *)         die "unknown argument: $1 (see './install.sh -h')" ;;
    esac
    shift
  done
  if [ "$system" -eq 1 ] && [ -n "$dir" ]; then die "use either --system or --dir, not both"; fi
  if [ -n "$dir" ]; then
    BIN_DIR="$dir"
  elif [ "$system" -eq 1 ]; then
    BIN_DIR="$SYSTEM_DIR"
  else
    : "${HOME:?install: HOME is not set}"
    BIN_DIR="$HOME/.local/bin"
  fi
  # absolute and without a trailing slash, so it can be compared with PATH entries
  case "$BIN_DIR" in
    /*) ;;
    *)  BIN_DIR="$PWD/$BIN_DIR" ;;
  esac
  while [ "${#BIN_DIR}" -gt 1 ] && [ "${BIN_DIR%/}" != "$BIN_DIR" ]; do BIN_DIR="${BIN_DIR%/}"; done
  if [ "$system" -eq 1 ] && [ "$MODE" = link ] && [ "$CHECK" -eq 0 ]; then
    info "note: symlinks in $SYSTEM_DIR point into $HERE; other users need read access to it (--copy installs standalone copies)"
  fi
}

main() {
  parse_args "$@"
  local tool
  for tool in "${TOOLS[@]}"; do
    process "$tool"
  done
  path_notes
  dep_notes
  return "$RC"
}
main "$@"
