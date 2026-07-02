# Praxec Packs

The registry of **workflow packs** and the **MCP tools** they depend on, for
[Praxec](https://github.com/praxec/praxec).

- A **pack** is a curated library of `cap.*` capabilities and `flow.*` orchestrators you load into
  a gateway via its multi-repo loader (pure YAML — nothing to install).
- A **tool** is a standalone MCP server a pack *spawns* as a `kind: mcp` connection (a real binary
  that has to exist on the machine).

This repo doesn't hold the packs or tools — it's the index that tracks **where they live, what
they provide, and how to get them**, so tooling and the [praxec.dev](https://praxec.dev) "packs"
page render from one machine-readable source: [`packs.yaml`](packs.yaml).

## Quick start — one command

Install the gateway (`cargo install praxec`), then provision a pack **and every MCP tool it needs**,
with a ready-to-run gateway config:

```bash
curl -fsSL https://raw.githubusercontent.com/praxec/packs/main/setup.sh | bash
# …or a specific pack:
curl -fsSL https://raw.githubusercontent.com/praxec/packs/main/setup.sh | bash -s -- cognitive-architectures
```

[`setup.sh`](setup.sh) reads this registry, downloads each required tool (release binary for your
platform, or a Docker shim as fallback) into `~/.praxec/bin`, clones the pack, walks you through
provider keys (`px set-provider-keys`), writes `~/praxec-workspace/gateway.yaml`, validates it with
`praxec check`, and prints the `praxec serve` command. That's the whole setup.

## Loading a pack

Point your gateway config at the pack's repo (cloned locally); every definition it ships is
namespace-prefixed:

```yaml
repos:
  - path: /path/to/cognitive-architectures   # → cognitive/flow.add-feature, cognitive/cap.plan.vet, …
```

See the [multi-repo loading guide](https://praxec.dev/docs/guides/multi-repo-loading) for namespacing
and collision rules.

## Getting a pack's tools

A pack's `requires:` lists the MCP tools its connections spawn. Each tool in `packs.yaml` carries an
ordered **provider chain** — praxec resolves a tool through it, preferring reproducibility:

```
docker image  →  release binary  →  cargo
```

`praxec doctor` detects which of a pack's required tools are missing and **offers** the provision
command (it never installs silently). Pick the provider that fits your deployment:

| Provider | Best for |
|----------|----------|
| `docker` (`ghcr.io/praxec/<tool>`, pinned) | reproducible + sandboxed + zero toolchain (any language) — the default |
| `release` (GitHub Releases binary) | low-friction native path, no Docker |
| `cargo` (crates.io) | Rust devs / source builds |

MCP tools are long-lived stdio processes (one per connection, not per call), so container startup
is amortized — the reproducibility/sandbox win comes with negligible per-call cost.

> **Status.** The `providers.*` and `mcp_registry_id` fields are the *canonical target coordinates*
> for each tool. Publishing the artifacts — container images, release binaries, and
> [official MCP registry](https://registry.modelcontextprotocol.io) entries — is CI follow-up; the
> registry consumes these coordinates so praxec (and any MCP host) can resolve tools by a standard id.

## Schema (`praxec.packs/v2`)

**Pack:** `id` · `name` · `namespace` · `description` · `repo` · `tier` (`open`|`premium`) · `tags` ·
`requires` (tool ids) · `extends` (base pack id, optional) · `external` (third-party/closed tools the
operator wires themselves).

**Tool:** `id` · `name` · `description` · `repo` · `command` (the spawnable binary) · `version` ·
`mcp_registry_id` · `providers` (`docker` / `release` / `cargo`).

## Adding an entry

Open a PR editing `packs.yaml` (entries grouped, alphabetical by `id`). A pack must ship a valid
`praxec.repo.yaml` manifest in its repo root; a tool must publish at least one provider.

## License

The registry (this repo and `packs.yaml`) is [BSD-3-Clause](LICENSE). Individual packs and tools
carry their own licenses — see each repo.
