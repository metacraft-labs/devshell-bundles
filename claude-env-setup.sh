#!/usr/bin/env bash
#
# claude-env-setup.sh — setup script for a Claude Code cloud environment.
# Restores one workspace project from a devshell bundle (build-bundle.sh +
# upload-bundle.sh): its dev-shell closure into /nix/store and its repos'
# source code into the workspace directory, with no evaluation and no clones.
#
# Paste the whole file into the environment's "Setup script" field and set
# PROJECT and BASE below. The setup script cannot read the environment's
# variables or secrets, so BASE carries the capability prefix inline; treat the
# environment's settings as the place that secret lives.
#
# Budget, from measurements in a cloud session (2026-11-04, 4 vCPU, IAD):
#   download    16 parallel streams ~375 MB/s, into /dev/shm (RAM)
#   decompress  zstd ~720 MB/s out
#   extract     disk-bound, ~165 MB/s of unpacked files
# so the UNPACKED size sets the time: ~6 s per GiB. The same session had about
# 31 GB of writable disk in total, which bounds what a bundle may unpack to.
set -uo pipefail

PROJECT="${PROJECT:-codetracer}"
BASE="${DEVSHELL_BASE:-https://devshells.metacraft-labs.com/REPLACE_WITH_PREFIX}"
# Or a private GitHub repository published by upload-github.sh. The session's
# proxy authenticates the requests when the repository is attached to the
# environment (Repositories in its settings).
GITHUB_REPO="${DEVSHELL_GITHUB_REPO:-}"
# Where the workspace's repos go. The script starts one directory above the
# environment's own repository checkouts, and those take precedence: files that
# already exist are never overwritten.
SOURCES_PARENT="${DEVSHELL_SOURCES_PARENT:-$PWD}"
SYSTEM="x86_64-linux"
PARALLEL=16
BUDGET_SECONDS=270
# Tests only: restore the store into a separate root instead of the real one.
ROOT="${DEVSHELL_ROOT:-/}"
store=(); [[ "$ROOT" != / ]] && store=(--store "$ROOT")

start=$(date +%s)
# Keep a log a later session can read: the environment's own setup log shows
# only that the script ran, not what it did.
LOG="${DEVSHELL_LOG:-/var/log/devshell-bundle.log}"
exec > >(tee -a "$LOG") 2>&1
echo "[devshell-bundle] $(date -u +%FT%TZ) project=$PROJECT source=${GITHUB_REPO:-$BASE}"
log() { echo "[devshell-bundle +$(( $(date +%s) - start ))s] $*"; }
left() { echo $(( BUDGET_SECONDS - ($(date +%s) - start) )); }

. /etc/profile.d/nix.sh 2>/dev/null || true
command -v nix-store >/dev/null || { log "nix not installed; skipping"; exit 0; }

work="$(mktemp -d /dev/shm/devshell-bundle.XXXXXX)"
trap 'rm -rf "$work"' EXIT
url="$BASE/$PROJECT"
# get <out> <path under the project> [<github branch>]
get() {
  if [[ -n "$GITHUB_REPO" ]]; then
    local ref; ref="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$3")"
    curl -fsSL --retry 3 -H 'Accept: application/vnd.github.raw' -o "$1" \
      "https://api.github.com/repos/$GITHUB_REPO/contents/$2?ref=$ref"
  else
    curl -fsS --retry 3 -o "$1" "$url/$2"
  fi
}
export -f get; export GITHUB_REPO url
if [[ -n "$GITHUB_REPO" ]]; then
  get "$work/latest.json" "$PROJECT/$SYSTEM/latest.json" latest
else
  get "$work/latest.json" "$SYSTEM/latest.json"
fi || { log "no bundle published for $PROJECT ${GITHUB_REPO:-at $url}"; exit 0; }

# Sets cid, sid, zstd_path, c_bytes, c_unpacked, s_bytes, wsdir, primary_env, roots.
cid="" sid="" zstd_path="" c_bytes=0 c_unpacked=0 s_bytes=0 wsdir="" primary_env="" roots=()
eval "$(python3 -I - "$work/latest.json" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1])); q = shlex.quote
c, s = m["closure"], m.get("sources")
shells = c["shells"]
primary = shells.get(c.get("primary") or "", next(iter(shells.values())))
print(f"cid={q(c['id'])} zstd_path={q(c['zstd'])} c_unpacked={c['unpacked_bytes']}")
print(f"c_bytes={sum(p['bytes'] for p in c['parts'])} primary_env={q(primary['env'])}")
print("roots=(" + " ".join(q(x[k]) for x in shells.values() for k in ("input", "env")) + ")")
if s:
    print(f"sid={q(s['id'])} wsdir={q(s['workspace_dir'])} s_bytes={sum(p['bytes'] for p in s['parts'])}")
PY
)"

# fetch <remote dir> <closure|sources>: parallel download into $work, then verify.
fetch() {
  python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))[sys.argv[2]]
files = m["parts"] + ([m["registration"]] if "registration" in m else [])
with open(sys.argv[3], "w") as sums, open(sys.argv[4], "w") as jobs:
    for p in files:
        sums.write(p["sha256"] + "  " + p["file"] + "\n")
        jobs.write(p["file"] + "\t" + p.get("ref", "") + "\n")' \
    "$work/latest.json" "$2" "$work/$2.sums" "$work/$2.jobs"
  ( cd "$work" && while IFS=$'\t' read -r f ref; do
      if [[ -n "$GITHUB_REPO" ]]; then printf '%s\0%s\0%s\0' "$f" "$f" "$ref"
      else printf '%s\0%s\0%s\0' "$f" "$1/$f" ""; fi
    done < "$work/$2.jobs" | xargs -0 -n3 -P "$PARALLEL" bash -c 'get "$0" "$1" "$2"' ) || return 1
  ( cd "$work" && sha256sum --quiet -c "$work/$2.sums" )
}

need_closure=1
nix-store "${store[@]}" --check-validity "${roots[@]}" 2>/dev/null && need_closure=0
total=$(( need_closure * c_bytes + s_bytes ))
# RAM is faster than this disk and the parts are deleted after use; fall back
# to disk when they would not leave room in /dev/shm.
if (( total * 2 > $(df --output=avail -B1 /dev/shm | tail -1) )); then
  disk="$(mktemp -d /var/tmp/devshell-bundle.XXXXXX)"
  mv "$work/latest.json" "$disk/"; rm -rf "$work"; work="$disk"
fi

if (( need_closure )); then
  log "closure $cid: $((c_bytes >> 20)) MiB to download, $((c_unpacked >> 20)) MiB to unpack"
  # zstd is not installed in the image; one small path from cache.nixos.org.
  nix-store --realise "$zstd_path" >/dev/null 2>&1 || { log "cannot fetch zstd"; exit 0; }
  fetch "$SYSTEM/$cid" closure || { log "closure download failed or did not verify"; exit 0; }
  log "closure downloaded"
  # Store paths are written directly, then registered, the way a NixOS
  # installer image seeds its store. --skip-old-files leaves paths that are
  # already in the store untouched.
  if ! cat "$work"/part-* | "$zstd_path/bin/zstd" -q -d --long=27 \
      | timeout "$(left)" tar -C "$ROOT" --skip-old-files -xf -; then
    log "closure unpack did not finish in the budget"; exit 0
  fi
  rm -f "$work"/part-*
  "$zstd_path/bin/zstd" -q -d -c "$work/registration" | nix-store "${store[@]}" --load-db
  nix-store "${store[@]}" --check-validity "${roots[@]}" || { log "registration incomplete"; exit 0; }
  log "closure unpacked and registered"
else
  log "closure $cid already present"
fi

if [[ -n "$sid" ]]; then
  marker="$SOURCES_PARENT/$wsdir/.repro/devshell-sources-id"
  if [[ "$(cat "$marker" 2>/dev/null)" == "$sid" ]]; then
    log "sources $sid already present"
  else
    log "sources $sid: $((s_bytes >> 20)) MiB to download"
    [[ -x "$zstd_path/bin/zstd" ]] || nix-store --realise "$zstd_path" >/dev/null 2>&1
    if fetch "sources/$sid" sources \
      && cat "$work"/src-* | "$zstd_path/bin/zstd" -q -d --long=27 \
          | timeout "$(left)" tar -C "$SOURCES_PARENT" --skip-old-files -xf -; then
      mkdir -p "$(dirname "$marker")"; echo "$sid" > "$marker"
      log "sources unpacked into $SOURCES_PARENT/$wsdir"
    else
      log "sources did not download, verify or unpack in the budget"
    fi
    rm -f "$work"/src-*
  fi
fi

# Every Bash-tool shell starts inside the project's primary dev shell, without
# evaluating anything (the session's GitHub access is per repository, so
# evaluating `github:` flake inputs would fail there anyway).
[[ "$ROOT" == / ]] || { log "test root $ROOT: not activating"; exit 0; }
echo ". '$primary_env'" > /etc/profile.d/zz-devshell.sh
log "dev shell activated via /etc/profile.d/zz-devshell.sh"
exit 0
