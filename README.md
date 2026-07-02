# Praxec Packs

A registry of **capability & workflow packs** for [Praxec](https://github.com/praxec/praxec) —
curated libraries of `cap.*` capabilities and `flow.*` orchestrators you load into a Praxec
gateway through its multi-repo loader.

This repo doesn't hold the packs themselves. It's the index that tracks **where they live, what
they provide, and how to load them** — so tools (and the [praxec.dev](https://praxec.dev) site's
"available packs" page) can render the catalog from one machine-readable source: [`packs.yaml`](packs.yaml).

## Loading a pack

Point your gateway config at the pack's repo (cloned locally), and every definition it ships is
namespace-prefixed:

```yaml
repos:
  - path: /path/to/cognitive-architectures   # → cognitive/flow.add-feature, cognitive/cap.plan.vet, …
```

See the Praxec [multi-repo loading guide](https://praxec.dev/docs/guides/multi-repo-loading) for
namespacing and collision rules.

## The registry

[`packs.yaml`](packs.yaml) is the source of truth. Each entry:

| Field | Meaning |
|-------|---------|
| `id` | Stable slug |
| `name` | Human-readable name |
| `namespace` | The prefix every definition loads under |
| `description` | One-paragraph summary |
| `repo` | Where the pack lives |
| `tier` | `open` (freely loadable) or `premium` (paid/licensed) |
| `tags` | Free-form discovery tags |

## Adding a pack

Open a PR adding an entry to `packs.yaml`. Keep entries alphabetical by `id`; a pack must ship a
valid `praxec.repo.yaml` manifest in its repo root.

## License

The registry (this repo and `packs.yaml`) is [BSD-3-Clause](LICENSE). Individual packs carry their
own licenses — see each pack's repo.
