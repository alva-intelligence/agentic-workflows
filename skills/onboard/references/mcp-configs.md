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

## Lark (CLI-based, replaces the old Lark MCP)

**Lark integration no longer uses an MCP server.** Lark access is now provided via the official `lark-cli` tool, exposed to agents through the `/lark-sync` skill. This gives broader coverage (tasks, sections, custom fields, docs, calendar, etc.) and avoids MCP server startup cost on every session.

**To set up on a new machine:**

```bash
npm install -g @larksuite/cli
npx skills add larksuite/cli -s lark-task -y -g   # agent skill pack (optional)
# Configure the Alva Lark app — contact arhen for App ID + Secret:
printf '%s' '<LARK_APP_SECRET>' | lark-cli config init --app-id '<LARK_APP_ID>' --app-secret-stdin --brand lark
# Log in as your user, requesting all required scopes (tasks + docs + base + drive + wiki):
lark-cli auth login --scope 'task:task:read task:task:write task:tasklist:read task:tasklist:write task:section:read task:section:write task:comment:read task:comment:write task:custom_field:read task:custom_field:write task:attachment:read task:attachment:write docs:document.content:read docx:document:readonly bitable:app bitable:app:readonly drive:drive drive:file drive:file:download drive:export:readonly wiki:wiki wiki:wiki:readonly wiki:node:read wiki:node:retrieve wiki:node:create wiki:node:copy wiki:node:move wiki:space:read wiki:space:retrieve wiki:space:write_only wiki:member:create wiki:member:retrieve wiki:member:update offline_access'
# Link this workspace to the team's shared tasklist:
/lark-sync link <TASKLIST_GUID>
```

**If you already had the old Lark MCP configured, REMOVE it:**

- Claude Code (`.mcp.json`): remove the `mcpServers.lark` entry
- Cursor (`.cursor/mcp.json`): remove the `mcpServers.lark` entry
- OpenCode (`opencode.json`): remove the `mcp.lark` entry
- Amp (`.amp/settings.json`): remove the `amp.mcpServers.lark` entry
- Also drop any Lark-specific entries from `.claude/settings.local.json` under `mcpServers` or `enabledMcpjsonServers`/`disabledMcpjsonServers` that reference `lark`

After removal, restart the agent so it picks up the clean MCP state.

**Credentials:** Contact arhen for the Lark App ID and Secret. See `skills/lark-sync/SKILL.md` for day-to-day usage.

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
