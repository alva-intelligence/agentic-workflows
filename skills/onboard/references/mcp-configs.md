# MCP Configuration Templates

All MCP configs follow tool-specific formats. Merge these into the appropriate config file — don't overwrite existing entries.

**Format differences by tool:**

| Tool | Config File | MCP Root Key | Command Format | Env Key |
|------|-------------|-------------|----------------|---------|
| Claude Code | `.mcp.json` | `mcpServers` | `"command": "npx", "args": [...]` | `env` |
| Cursor | `.cursor/mcp.json` | `mcpServers` | `"command": "npx", "args": [...]` | `env` |
| OpenCode | `opencode.json` | `mcp` | `"type": "local", "command": ["npx", ...], "enabled": true` | `environment` |
| Amp | `.amp/settings.json` | `amp.mcpServers` | `"command": "npx", "args": [...]` | `env` |

> **Amp note:** The key `amp.mcpServers` is a flat property in `.amp/settings.json`, NOT nested under an `amp` object. Remote/HTTP MCPs use `"url"` and `"headers"` instead of `command`/`args`. User-level config at `~/.config/amp/settings.json` uses the same format. You can also use `amp mcp add <name> -- <cmd> <args>` or `amp mcp add <name> <url>` to add servers via CLI.

---

## Context7 (Required — all services)

Package: `@upstash/context7-mcp`

### Claude Code (`.mcp.json`)

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

### Cursor (`.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

### OpenCode (`opencode.json`)

```json
{
  "mcp": {
    "context7": {
      "type": "local",
      "command": ["npx", "-y", "@upstash/context7-mcp"],
      "enabled": true
    }
  }
}
```

### Amp (`.amp/settings.json`)

```json
{
  "amp.mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

---

## Agentation MCP (Required — all services)

Package: `agentation-mcp`

Turns visual UI feedback into structured context for coding agents: click elements in the browser, add notes, and the agent receives CSS selectors, file paths, React component trees, computed styles, and user feedback directly — no copy-paste. See [agentation.com/mcp](https://www.agentation.com/mcp).

**No credentials required.**

### Claude Code (`.mcp.json`)

```json
{
  "mcpServers": {
    "agentation": {
      "command": "npx",
      "args": ["-y", "agentation-mcp", "server"]
    }
  }
}
```

Or via CLI: `claude mcp add agentation -- npx -y agentation-mcp server`

### Cursor (`.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "agentation": {
      "command": "npx",
      "args": ["-y", "agentation-mcp", "server"]
    }
  }
}
```

### OpenCode (`opencode.json`)

```json
{
  "mcp": {
    "agentation": {
      "type": "local",
      "command": ["npx", "-y", "agentation-mcp", "server"],
      "enabled": true
    }
  }
}
```

### Amp (`.amp/settings.json`)

```json
{
  "amp.mcpServers": {
    "agentation": {
      "command": "npx",
      "args": ["-y", "agentation-mcp", "server"]
    }
  }
}
```

Or via CLI: `amp mcp add agentation -- npx -y agentation-mcp server`

### Auto-detect across installed tools

The `add-mcp` utility writes the correct config into every detected tool in one command:

```bash
npx add-mcp "npx -y agentation-mcp server"
```

---

## GitHub MCP (Required — all services)

Package: `@modelcontextprotocol/server-github`

### Claude Code (`.mcp.json`)

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "<your-github-pat>"
      }
    }
  }
}
```

### Cursor (`.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "<your-github-pat>"
      }
    }
  }
}
```

### OpenCode (`opencode.json`)

```json
{
  "mcp": {
    "github": {
      "type": "local",
      "command": ["npx", "-y", "@modelcontextprotocol/server-github"],
      "enabled": true,
      "environment": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "<your-github-pat>"
      }
    }
  }
}
```

### Amp (`.amp/settings.json`)

```json
{
  "amp.mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "<your-github-pat>"
      }
    }
  }
}
```

**Credentials:** Use the same PAT from `gh auth` or generate one at https://github.com/settings/tokens

---

## Laravel Boost MCP (Required — API service only)

Package: `@nicholasgriffintn/laravel-boost-mcp`

Configure inside `api/` directory only.

### Claude Code (`api/.mcp.json`)

```json
{
  "mcpServers": {
    "laravel-boost": {
      "command": "npx",
      "args": ["-y", "@nicholasgriffintn/laravel-boost-mcp"]
    }
  }
}
```

### Cursor (`api/.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "laravel-boost": {
      "command": "npx",
      "args": ["-y", "@nicholasgriffintn/laravel-boost-mcp"]
    }
  }
}
```

### OpenCode (`api/opencode.json`)

```json
{
  "mcp": {
    "laravel-boost": {
      "type": "local",
      "command": ["npx", "-y", "@nicholasgriffintn/laravel-boost-mcp"],
      "enabled": true
    }
  }
}
```

### Amp (`api/.amp/settings.json`)

```json
{
  "amp.mcpServers": {
    "laravel-boost": {
      "command": "npx",
      "args": ["-y", "@nicholasgriffintn/laravel-boost-mcp"]
    }
  }
}
```

---

## Sentry MCP (Optional — production debugging)

Package: `@sentry/mcp-server`

### Claude Code (`.mcp.json`)

```json
{
  "mcpServers": {
    "sentry": {
      "command": "npx",
      "args": ["-y", "@sentry/mcp-server"],
      "env": {
        "SENTRY_AUTH_TOKEN": "<your-sentry-token>"
      }
    }
  }
}
```

### Cursor (`.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "sentry": {
      "command": "npx",
      "args": ["-y", "@sentry/mcp-server"],
      "env": {
        "SENTRY_AUTH_TOKEN": "<your-sentry-token>"
      }
    }
  }
}
```

### OpenCode (`opencode.json`)

```json
{
  "mcp": {
    "sentry": {
      "type": "local",
      "command": ["npx", "-y", "@sentry/mcp-server"],
      "enabled": true,
      "environment": {
        "SENTRY_AUTH_TOKEN": "<your-sentry-token>"
      }
    }
  }
}
```

### Amp (`.amp/settings.json`)

```json
{
  "amp.mcpServers": {
    "sentry": {
      "command": "npx",
      "args": ["-y", "@sentry/mcp-server"],
      "env": {
        "SENTRY_AUTH_TOKEN": "<your-sentry-token>"
      }
    }
  }
}
```

**Credentials:** Generate at https://sentry.io/settings/account/api/auth-tokens/

---

## Lark (Optional — read pasted Lark links via the Lark CLI)

**Read-only, through the Lark CLI — never an MCP.** When the user pastes a Lark doc link (PRD brief, wiki page), the agent reads it through the Lark CLI the user connected once. **No MCP config exists for Lark in this workflow** and the workflow never writes to Lark — no doc, wiki, or task sync.

Connect once (done during onboarding 1.4 / re-doable anytime):
1. Install the official Lark CLI per its docs and authenticate with the account that owns the docs.
2. Verify: user pastes any Lark doc URL → CLI doc-fetch returns the content.
3. Record `lark_cli: "connected"` in `.onboard-state.json` (or `"skipped"` — until connected, Lark links are handled by the user pasting text).

**Removing a legacy Lark MCP** (older workspace installs): delete the `lark` entry from `.mcp.json` / `.cursor/mcp.json` / `opencode.json` / `.amp/settings.json`, remove the App ID/Secret from wherever it was stored, and treat the credential as revoked. The CLI never needs an App ID/Secret pair for the read-only link fetches this workflow does.

---

## Figma MCP (Optional — design-to-code)

**Remote server** — no npm package needed. Connects to `https://mcp.figma.com/mcp`.

### Claude Code

Run this command (or add manually to `.mcp.json`):
```bash
claude mcp add --transport http figma https://mcp.figma.com/mcp
```

Or manually in `.mcp.json`:
```json
{
  "mcpServers": {
    "figma": {
      "url": "https://mcp.figma.com/mcp",
      "type": "http"
    }
  }
}
```

### Cursor

Use the Cursor plugin system:
```
/add-plugin figma
```

Or manually in `.cursor/mcp.json`:
```json
{
  "mcpServers": {
    "figma": {
      "url": "https://mcp.figma.com/mcp",
      "type": "http"
    }
  }
}
```

### OpenCode (`opencode.json`)

```json
{
  "mcp": {
    "figma": {
      "type": "remote",
      "url": "https://mcp.figma.com/mcp",
      "enabled": true
    }
  }
}
```

### Amp (`.amp/settings.json`)

```json
{
  "amp.mcpServers": {
    "figma": {
      "url": "https://mcp.figma.com/mcp"
    }
  }
}
```

Or via CLI: `amp mcp add figma https://mcp.figma.com/mcp`

**No API token needed** — authenticates via browser OAuth when first used.
See: https://help.figma.com/hc/en-us/articles/32132100833559
