# MCP Configuration Templates

## Lark MCP

### Claude Code (`.claude/settings.local.json`)

```json
{
  "mcpServers": {
    "lark": {
      "command": "npx",
      "args": ["-y", "@anthropic/lark-mcp"],
      "env": {
        "LARK_APP_ID": "<from-team-lead>",
        "LARK_APP_SECRET": "<from-team-lead>"
      }
    }
  }
}
```

### Cursor (`.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "lark": {
      "command": "npx",
      "args": ["-y", "@anthropic/lark-mcp"],
      "env": {
        "LARK_APP_ID": "<from-team-lead>",
        "LARK_APP_SECRET": "<from-team-lead>"
      }
    }
  }
}
```

### OpenCode (`opencode.json`)

```json
{
  "mcp": {
    "lark": {
      "command": "npx",
      "args": ["-y", "@anthropic/lark-mcp"],
      "env": {
        "LARK_APP_ID": "<from-team-lead>",
        "LARK_APP_SECRET": "<from-team-lead>"
      }
    }
  }
}
```

**Credentials:** Contact arhen for the Lark App ID and Secret.

---

## Figma MCP

### Claude Code (`.claude/settings.local.json`)

```json
{
  "mcpServers": {
    "figma": {
      "command": "npx",
      "args": ["-y", "@anthropic/figma-mcp"],
      "env": {
        "FIGMA_ACCESS_TOKEN": "<your-personal-access-token>"
      }
    }
  }
}
```

### Cursor (`.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "figma": {
      "command": "npx",
      "args": ["-y", "@anthropic/figma-mcp"],
      "env": {
        "FIGMA_ACCESS_TOKEN": "<your-personal-access-token>"
      }
    }
  }
}
```

### OpenCode (`opencode.json`)

```json
{
  "mcp": {
    "figma": {
      "command": "npx",
      "args": ["-y", "@anthropic/figma-mcp"],
      "env": {
        "FIGMA_ACCESS_TOKEN": "<your-personal-access-token>"
      }
    }
  }
}
```

**Credentials:** Generate a personal access token at https://www.figma.com/developers/api#access-tokens
