# Prompt plugins

A plugin changes **how the agent behaves**, not what tools it has. It is a
folder of Markdown prompt modules plus a manifest; the enabled modules are
concatenated into the system prompt on every request, next to the skill and MCP
metadata.

This is the same shape as a DSH plugin: `modules[]` select what gets injected,
a profile presets a combination, and edits apply immediately — the files are
read per turn, so there is nothing to reload.

Plugins are not skills and not MCP servers. A skill is loaded on demand when a
request matches it; a plugin is always present while enabled. An MCP server adds
tools; a plugin adds judgment and formatting rules.

## Layout

```
<pluginsRoot>/<plugin-id>/
    plugin.json
    prompts/
        core.md
        output.md
```

`<pluginsRoot>` is `plugins/` inside the Minis app-group container, which is the
`plugins/` folder visible in **Files → On My iPhone → Minis**.

## plugin.json

```json
{
  "schemaVersion": 1,
  "id": "output-style",
  "name": "Output Style",
  "version": "1.0.0",
  "description": "Answer-shape rules.",
  "author": "you",
  "priority": 10,
  "modules": [
    { "id": "core", "name": "Conclusion first", "file": "prompts/core.md", "default": true },
    { "id": "terse", "name": "Terse mode", "file": "prompts/terse.md", "default": false }
  ],
  "profiles": {
    "base": ["core"],
    "full": ["*"]
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Directory name. `[a-z0-9][a-z0-9._-]{1,63}` — it cannot escape the plugins root. |
| `name` | yes | Shown in Settings. |
| `version` | yes | Shown in Settings; informational. |
| `schemaVersion` | no | Reserved. |
| `description` | no | One line, shown on the detail page and injected as the section subtitle. |
| `author` | no | Shown on the detail page. |
| `priority` | no | Sort key. Higher runs **later** in the assembled prompt, i.e. closer to the user turn. |
| `modules[]` | yes | At least one. Order here is the injection order. |
| `modules[].id` | yes | Unique within the package. |
| `modules[].name` | no | Falls back to the id. |
| `modules[].file` | yes | Path relative to the plugin root. `..` and absolute paths are rejected. |
| `modules[].default` | no | Starts enabled. A module without it starts off. |
| `profiles` | no | Named module sets. `["*"]` expands to every module. |

## Injection

For each enabled plugin, in `priority` order:

```
## Plugin: <name> v<version>
<description>

<module 1 text>

<module 2 text>
```

Limits: 32,000 characters per plugin, 64,000 for all plugins together. Over the
limit the text is clipped rather than dropped, so the tail of a runaway module
disappears instead of the whole plugin.

## Selection state

The user's enable switch and module choices live in `plugins-state.json` under
the app's config container, **not** in the package. That is what lets a
reinstall from an updated folder keep the user's choices — an update cannot
silently re-enable modules they turned off.

`activeModules` is `null` until the user touches a switch, meaning "follow the
manifest defaults". So a package that later marks a new module `default: true`
gets it enabled for users who never made an explicit choice.

## Installing

**Settings → Agent Runtime → Plugins → +**, then pick the plugin folder. The
folder must contain `plugin.json` at its top level.

Install copies the folder into the plugins root. Remove deletes the copy and
its selection state.

## Migrating a DSH plugin

DSH uses `config.json` with a `modules` array plus `prompts/*.md` files. The
mapping is mechanical:

- `config.json` → `plugin.json`
- `modules: ["core","output"]` → a module entry per file, with `default: true`
  on the ones enabled in the DSH config
- `profiles` → copied as-is
- `identity` → belongs in SOUL.md, not a plugin; drop it

A DSH package that ships ten modules and eight profiles translates directly:
each module becomes one entry, each profile becomes one key.