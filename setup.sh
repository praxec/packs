#!/bin/sh
# Praxec — 1-command pack setup.
#
# Provisions a workflow pack + every MCP tool it needs, points you at provider
# keys, wires a gateway config, validates it, and leaves you ready to serve.
# Assumes the `praxec` gateway binary is already installed:
#   curl -fsSL https://raw.githubusercontent.com/praxec/praxec/main/install.sh | sh
#
#   curl -fsSL https://raw.githubusercontent.com/praxec/packs/main/setup.sh | sh
#   # …or, for a specific pack:
#   curl -fsSL https://raw.githubusercontent.com/praxec/packs/main/setup.sh | sh -s -- cognitive-architectures
#
# POSIX sh — no bash required. Needs: sh, curl or wget, tar, git, python3+PyYAML.
set -eu

PACK="${1:-cognitive-architectures}"
REGISTRY="${PRAXEC_REGISTRY:-https://raw.githubusercontent.com/praxec/packs/main/packs.yaml}"
HOME_DIR="${PRAXEC_HOME:-$HOME/.praxec}"
BIN_DIR="$HOME_DIR/bin"
WORK="${PRAXEC_WORKSPACE:-$HOME/praxec-workspace}"
say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Package-manager hint so every missing-dependency message is actionable
# instead of a bare `-sh: X: not found`.
pkg_hint() {
  if   command -v apt-get >/dev/null 2>&1; then echo "apt-get install -y $1"
  elif command -v apk     >/dev/null 2>&1; then echo "apk add $1"
  elif command -v dnf     >/dev/null 2>&1; then echo "dnf install -y $1"
  elif command -v pacman  >/dev/null 2>&1; then echo "pacman -S $1"
  elif command -v brew    >/dev/null 2>&1; then echo "brew install $1"
  else echo "install '$1' with your system package manager"; fi
}
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required — $(pkg_hint "$1")"; }

# Fetch tool: curl OR wget (busybox wget works). A minimal box may have neither —
# the one-liner needs one to have fetched THIS script, but be explicit anyway.
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
else
  die "need 'curl' or 'wget' to download packs + tools ($(pkg_hint curl) — or $(pkg_hint wget))."
fi

mkdir -p "$BIN_DIR" "$WORK"

# ── deps ─────────────────────────────────────────────────────────────────────
command -v praxec >/dev/null 2>&1 || die "the 'praxec' gateway binary isn't on PATH — install it first:
    curl -fsSL https://raw.githubusercontent.com/praxec/praxec/main/install.sh | sh"
need tar
need git
need python3
need mktemp
# The registry is YAML; we parse it with python3 + PyYAML. Make that dependency
# loud and honest instead of letting python die on a bare ImportError traceback.
python3 -c 'import yaml' 2>/dev/null || die "python3 is missing PyYAML (required to read the pack registry). Install it:
    pip install pyyaml        # or:  apt-get install -y python3-yaml  /  apk add py3-yaml  /  dnf install -y python3-pyyaml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# ── target triple(s) for release binaries ────────────────────────────────────
# Praxec-family releases ship static `-musl` Linux builds; try musl first and
# fall back to `-gnu` (musl runs on Alpine/busybox where gnu would break/404).
os=$(uname -s); arch=$(uname -m)
case "$os:$arch" in
  Linux:x86_64)               TARGETS="x86_64-unknown-linux-musl x86_64-unknown-linux-gnu" ;;
  Linux:aarch64|Linux:arm64)  TARGETS="aarch64-unknown-linux-musl aarch64-unknown-linux-gnu" ;;
  Darwin:x86_64)              TARGETS="x86_64-apple-darwin" ;;
  Darwin:arm64)               TARGETS="aarch64-apple-darwin" ;;
  *) die "unsupported platform $os/$arch — install the tools manually (see the pack registry)" ;;
esac

# ── resolve pack + its required tools from the registry ──────────────────────
say "Reading the pack registry"
fetch "$REGISTRY" "$tmp/packs.yaml" || die "cannot fetch registry: $REGISTRY"
RESOLVED=$(python3 - "$PACK" "$tmp/packs.yaml" <<'PY'
import sys, yaml, shlex
pack_id = sys.argv[1]
with open(sys.argv[2]) as f:
    reg = yaml.safe_load(f)
packs = {p["id"]: p for p in reg.get("packs", [])}
tools = {t["id"]: t for t in reg.get("tools", [])}
if pack_id not in packs:
    sys.exit(f"pack '{pack_id}' not in registry (have: {', '.join(packs)})")
p = packs[pack_id]
# collect required tools, following `extends`
need, seen = [], set()
cur = p
while cur:
    for tid in cur.get("requires", []) or []:
        if tid not in seen: seen.add(tid); need.append(tid)
    cur = packs.get(cur.get("extends"))
print("PACK_REPO=" + shlex.quote(p["repo"]))
print("PACK_NS=" + shlex.quote(p.get("namespace", pack_id)))
ext = " ".join(p.get("external", []) or [])
print("EXTERNAL=" + shlex.quote(ext))
lines = []
for tid in need:
    t = tools[tid]
    lines.append("|".join([t["id"], t["command"], str(t["version"]), t["repo"], t["providers"].get("docker","")]))
print("TOOLS=" + shlex.quote(";".join(lines)))
PY
) || die "$RESOLVED"
eval "$RESOLVED"

# ── provision the tools (release binary → ~/.praxec/bin) ─────────────────────
say "Provisioning MCP tools for '$PACK' → $BIN_DIR"
# TOOLS is a ';'-separated list of '|'-joined records. Iterate line-by-line
# (no bash arrays / herestrings). We only warn inside the loop — a failure to
# provision one tool must not abort the whole setup — so the pipe subshell is fine.
printf '%s\n' "${TOOLS:-}" | tr ';' '\n' | while IFS='|' read -r id cmd ver repo docker; do
  [ -z "$cmd" ] && continue
  if [ -x "$BIN_DIR/$cmd" ] || command -v "$cmd" >/dev/null 2>&1; then
    say "  $cmd — already installed"; continue
  fi
  got=""
  for TARGET in $TARGETS; do
    url="$repo/releases/download/v$ver/$cmd-$TARGET.tar.gz"
    if fetch "$url" "$tmp/$cmd.tar.gz" 2>/dev/null \
       && tar xzf "$tmp/$cmd.tar.gz" -C "$BIN_DIR" 2>/dev/null \
       && [ -f "$BIN_DIR/$cmd" ]; then
      chmod +x "$BIN_DIR/$cmd"
      say "  $cmd v$ver ($TARGET)"
      got=1; break
    fi
  done
  if [ -n "$got" ]; then
    :
  elif command -v docker >/dev/null 2>&1 && [ -n "$docker" ]; then
    warn "  binary unavailable; pulling container $docker:$ver and shimming"
    if docker pull "$docker:$ver" >/dev/null 2>&1; then
      printf '#!/bin/sh\nexec docker run --rm -i %s:%s "$@"\n' "$docker" "$ver" > "$BIN_DIR/$cmd"
      chmod +x "$BIN_DIR/$cmd"
    else
      warn "  docker pull failed for $docker:$ver — install $cmd manually from $repo"
    fi
  else
    warn "  could not provision $cmd (no binary for $os/$arch, no docker) — install it manually from $repo"
  fi
done
[ -n "${EXTERNAL:-}" ] && warn "External deps (wire these yourself): $EXTERNAL"

# ── clone the pack ───────────────────────────────────────────────────────────
PACK_DIR="$WORK/$PACK"
if [ -d "$PACK_DIR/.git" ]; then say "Updating pack $PACK"; git -C "$PACK_DIR" pull -q || true
else say "Cloning pack $PACK"; git clone -q "$PACK_REPO" "$PACK_DIR"; fi

# ── co-load the base layers (cognitive-architectures + praxec-meta) ──────────
# Two layers are universal companions loaded beside ANY pack:
#   cognitive-architectures — the canonical SWE lifecycle flows + capabilities
#   praxec-meta             — the authoring surface (flow.author-flow / -capability)
# Without the authoring layer a fresh operator asking praxec "how do I author a
# flow?" gets nothing and hand-rolls YAML; without the base SWE layer the
# lifecycle flows are missing. Each is skipped if it IS the chosen pack (already
# loaded) or if its clone fails (best-effort — never blocks setup).
BASE_DIRS=""
add_base() { # $1 = repo id, $2 = git URL
  [ "$PACK" = "$1" ] && return 0   # chosen pack IS this base — already loaded above
  d="$WORK/$1"
  if [ -d "$d/.git" ]; then say "Updating base layer ($1)"; git -C "$d" pull -q || true
  else say "Cloning base layer ($1)"; git clone -q "$2" "$d" || { warn "could not clone $1; continuing without it"; return 0; }; fi
  [ -d "$d/.git" ] && BASE_DIRS="$BASE_DIRS $d"
}
add_base cognitive-architectures https://github.com/praxec/cognitive-architectures.git
add_base praxec-meta https://github.com/praxec/praxec-meta.git

# ── provider keys (easy) ─────────────────────────────────────────────────────
KEYS="$HOME_DIR/providers.env"
if [ -s "$KEYS" ]; then
  say "Provider keys already set ($KEYS)"
elif [ -t 0 ] && command -v px >/dev/null 2>&1; then
  say "Setting up provider API keys"
  px set-provider-keys || warn "skipped key setup — run 'px set-provider-keys' later"
else
  # `px` isn't shipped on a binary-only box; point at the provider-key helper
  # (or just export a key). Never fail here — keys are runtime, not setup-time.
  warn "No provider keys yet. Set them up with the provider-key helper:"
  warn "    curl -fsSL https://raw.githubusercontent.com/praxec/praxec/main/configure-providers.sh | sh"
  warn "  …or export one directly, e.g.:  export OPENROUTER_API_KEY=sk-..."
fi

# ── gateway config ───────────────────────────────────────────────────────────
CFG="$WORK/gateway.yaml"
if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<YAML
version: "1.0.0"
# Durable governance state + audit (see praxec.dev/docs/guides/production).
store: { kind: sqlite, path: $HOME_DIR/praxec.db }
audit: { sink: file, path: $HOME_DIR/audit }
# The '$PACK' pack — every definition loads under the '$PACK_NS/' namespace.
repos:
  - path: $PACK_DIR
YAML
  # Co-load the base layers (canonical SWE + authoring) so the lifecycle flows
  # AND flow.author-flow are present + discoverable out of the box.
  for d in $BASE_DIRS; do printf '  - path: %s\n' "$d" >> "$CFG"; done
  say "Wrote $CFG"
else
  say "Keeping existing $CFG"
fi

# ── validate ─────────────────────────────────────────────────────────────────
export PATH="$BIN_DIR:$PATH"
say "Validating"
if praxec check --config "$CFG"; then
  cat <<DONE

$(printf '\033[1;32m✓ Ready.\033[0m') '$PACK' + its tools are provisioned and wired.

  export PATH="$BIN_DIR:\$PATH"
  praxec serve --config $CFG

Then point any MCP client at it (command: praxec, args: serve --config $CFG),
or drive it headless with px (if installed): px walk --config $CFG --workflow $PACK_NS/flow.add-feature
DONE
else
  # A fresh box often has no provider keys / models.yaml yet, so `praxec check`
  # can legitimately report problems. Degrade to a warning rather than aborting —
  # the tools are provisioned and the config is written; the user can re-check.
  warn "praxec check reported problems (often expected on a fresh box before provider keys / models are set)."
  warn "Tools are in $BIN_DIR; config at $CFG. Fix the errors above, then re-run:"
  warn "    export PATH=\"$BIN_DIR:\$PATH\" && praxec check --config $CFG"
  cat <<DONE

Once check is clean:
  export PATH="$BIN_DIR:\$PATH"
  praxec serve --config $CFG
DONE
fi
