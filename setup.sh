#!/usr/bin/env bash
# Praxec — 1-command pack setup.
#
# Provisions a workflow pack + every MCP tool it needs, sets up your provider
# keys, wires a gateway config, validates it, and leaves you ready to serve.
# Assumes the `praxec` gateway binary is already installed (cargo install praxec).
#
#   curl -fsSL https://raw.githubusercontent.com/praxec/packs/main/setup.sh | bash
#   # or, for a specific pack:
#   curl -fsSL .../setup.sh | bash -s -- cognitive-architectures
#
set -euo pipefail

PACK="${1:-cognitive-architectures}"
REGISTRY="${PRAXEC_REGISTRY:-https://raw.githubusercontent.com/praxec/packs/main/packs.yaml}"
HOME_DIR="${PRAXEC_HOME:-$HOME/.praxec}"
BIN_DIR="$HOME_DIR/bin"
WORK="${PRAXEC_WORKSPACE:-$HOME/praxec-workspace}"
say()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$BIN_DIR" "$WORK"

# ── deps ─────────────────────────────────────────────────────────────────────
command -v praxec  >/dev/null || die "the 'praxec' gateway binary isn't on PATH — install it first: cargo install praxec"
command -v python3 >/dev/null || die "python3 is required to read the registry"
command -v curl >/dev/null && command -v tar >/dev/null && command -v git >/dev/null || die "need curl, tar, and git"

# ── target triple for release binaries ───────────────────────────────────────
os=$(uname -s); arch=$(uname -m)
case "$os:$arch" in
  Linux:x86_64)          TARGET=x86_64-unknown-linux-gnu ;;
  Linux:aarch64|Linux:arm64) TARGET=aarch64-unknown-linux-gnu ;;
  Darwin:x86_64)         TARGET=x86_64-apple-darwin ;;
  Darwin:arm64)          TARGET=aarch64-apple-darwin ;;
  *) die "unsupported platform $os/$arch — install the tools manually (see the pack registry)" ;;
esac

# ── resolve pack + its required tools from the registry ──────────────────────
say "Reading the pack registry"
REG=$(curl -fsSL "$REGISTRY") || die "cannot fetch registry: $REGISTRY"
RESOLVED=$(REG_CONTENT="$REG" python3 - "$PACK" <<'PY'
import os, sys, yaml, shlex
pack_id = sys.argv[1]
reg = yaml.safe_load(os.environ["REG_CONTENT"])
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
IFS=';' read -ra TOOL_ARR <<< "${TOOLS:-}"
for entry in "${TOOL_ARR[@]}"; do
  [ -z "$entry" ] && continue
  IFS='|' read -r id cmd ver repo docker <<< "$entry"
  if [ -x "$BIN_DIR/$cmd" ] || command -v "$cmd" >/dev/null 2>&1; then
    say "  $cmd — already installed"; continue
  fi
  url="$repo/releases/download/v$ver/$cmd-$TARGET.tar.gz"
  say "  $cmd v$ver ($TARGET)"
  if curl -fsSL "$url" | tar xz -C "$BIN_DIR" 2>/dev/null && [ -f "$BIN_DIR/$cmd" ]; then
    chmod +x "$BIN_DIR/$cmd"
  elif command -v docker >/dev/null 2>&1 && [ -n "$docker" ]; then
    warn "  binary unavailable; pulling container $docker:$ver and shimming"
    docker pull "$docker:$ver" >/dev/null
    printf '#!/usr/bin/env sh\nexec docker run --rm -i %s:%s "$@"\n' "$docker" "$ver" > "$BIN_DIR/$cmd"
    chmod +x "$BIN_DIR/$cmd"
  else
    warn "  could not provision $cmd (no binary for $TARGET, no docker) — install it manually from $repo"
  fi
done
[ -n "${EXTERNAL:-}" ] && warn "External deps (wire these yourself): $EXTERNAL"

# ── clone the pack ───────────────────────────────────────────────────────────
PACK_DIR="$WORK/$PACK"
if [ -d "$PACK_DIR/.git" ]; then say "Updating pack $PACK"; git -C "$PACK_DIR" pull -q || true
else say "Cloning pack $PACK"; git clone -q "$PACK_REPO" "$PACK_DIR"; fi

# ── provider keys (easy) ─────────────────────────────────────────────────────
KEYS="$HOME_DIR/providers.env"
if [ -s "$KEYS" ]; then
  say "Provider keys already set ($KEYS)"
elif [ -t 0 ] && command -v px >/dev/null 2>&1; then
  say "Setting up provider API keys"
  px set-provider-keys || warn "skipped key setup — run 'px set-provider-keys' later"
else
  warn "No provider keys yet. Set them with:  px set-provider-keys   (or export ANTHROPIC_API_KEY etc.)"
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
or drive it headless with:  px walk --config $CFG --workflow $PACK_NS/flow.add-feature
DONE
else
  die "praxec check failed — see the errors above. Tools are in $BIN_DIR; config at $CFG."
fi
