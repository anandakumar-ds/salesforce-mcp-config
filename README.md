# Exotel Salesforce MCP Configuration

Ready-to-use Salesforce MCP (Model Context Protocol) configuration for AI coding assistants at Exotel. Clone this repo and your AI tool can query Salesforce data using natural language.

## Supported Tools

| Tool | Config File | Auto-detected | Loads `CLAUDE.md`? |
|------|------------|---------------|---------------------|
| Claude Code | `.mcp.json` | Yes | **Yes (full 1,100 lines)** |
| Claude Desktop | see [Claude Desktop Setup](#claude-desktop-setup) | Manual (one-time) | No — paste [`EXOTEL_FIELD_GUIDE.md`](./EXOTEL_FIELD_GUIDE.md) into project instructions |
| OpenAI Codex CLI | `.codex/config.toml` | Yes | Partial — paste [`EXOTEL_FIELD_GUIDE.md`](./EXOTEL_FIELD_GUIDE.md) for reliable answers |
| VS Code (Copilot) | `.vscode/mcp.json` | Yes | No — paste [`EXOTEL_FIELD_GUIDE.md`](./EXOTEL_FIELD_GUIDE.md) into chat system prompt |
| Cursor | `.mcp.json` | Yes | Yes (Cursor reads `CLAUDE.md` and `.cursorrules`) |
| Windsurf | `.mcp.json` | Yes | Yes (Windsurf reads `CLAUDE.md`) |

## Quick Start (5 minutes)

### Step 1: Install Prerequisites

```bash
# macOS
brew install node

# Install Salesforce CLI globally (required)
npm install -g @salesforce/cli
```

> **Windows users:** Download Node.js from https://nodejs.org, then run `npm install -g @salesforce/cli` in PowerShell.

### Step 2: Authenticate to Salesforce

```bash
sf org login web -a ameyo -r https://ameyo.my.salesforce.com
```

This opens a browser window. Sign in with your `@exotel.com` Salesforce credentials.

**Verify it worked:**
```bash
sf org list
```
You should see `ameyo` listed with status `Connected`.

### Step 3: Clone This Repo

```bash
git clone https://github.com/shivanand-arch/salesforce-mcp-config.git
cd salesforce-mcp-config
```

### Step 4: Start Your AI Tool

**Claude Code** (recommended):
```bash
# From inside the cloned repo
claude
```
The MCP server starts automatically. Ask any Salesforce question.

**OpenAI Codex CLI:**
```bash
npm install -g @openai/codex
codex   # run from inside the cloned repo
```

**VS Code / Cursor / Windsurf:**
Open the `salesforce-mcp-config` folder in your IDE. The MCP config is auto-detected from `.vscode/mcp.json`.

### Step 5: Verify Connection

Type any of these to confirm it's working:
```
"List 5 recent opportunities"
"How many open cases are there?"
"Show me my org details"
```

If you see Salesforce data, you're good to go.

---

## Claude Desktop Setup

Claude Desktop requires manual MCP config.

**Step 1:** Get your shell PATH (Claude Desktop is a GUI app — it doesn't inherit your terminal's PATH, so `node`/`npx`/`sf` won't be found unless you pass it explicitly):
```bash
echo $PATH
```
Copy the output.

**Step 2:** Add this to your Claude Desktop settings (`Settings > Developer > Edit Config`), replacing `<your-shell-PATH>` with the output from Step 1:

```json
{
  "mcpServers": {
    "salesforce": {
      "command": "npx",
      "args": [
        "-y",
        "@salesforce/mcp",
        "--orgs", "ameyo",
        "--toolsets", "orgs,data,metadata,users",
        "--allow-non-ga-tools"
      ],
      "env": {
        "PATH": "<your-shell-PATH>",
        "HOME": "/Users/<your-username>",
        "NODE_NO_WARNINGS": "1"
      }
    }
  }
}
```

> **Prerequisite:** You must have completed Step 1 and Step 2 above (SF CLI installed + authenticated) before Claude Desktop can connect.
> **nvm / volta / fnm users:** The `echo $PATH` step is essential — your node binary lives in a version-specific directory that GUI apps can't discover on their own.

**Step 3 (CRITICAL — prevents wrong-data answers):** Claude Desktop does NOT auto-load `CLAUDE.md` from this repo. Without the field mappings, the model guesses field names and gives wrong numbers (e.g. returns ₹129 Cr for FY26 revenue instead of the real ₹569 Cr, because it uses `Opportunity.Amount` with `IsWon=true` instead of `accounts_revenue__c.Revenue_Booked_Amount__c`).

Fix: open [`EXOTEL_FIELD_GUIDE.md`](./EXOTEL_FIELD_GUIDE.md) in this repo, copy the whole file, paste it into Claude Desktop:

> **Settings → Projects → \<your project\> → Project instructions**

The guide is ~20k chars and covers 90% of real queries (revenue vs bookings split, pipeline stages, slang dictionary, key fields on Opportunity/Account/Case/Revenue, retention formulas, SOQL rules). Same applies to **ChatGPT, Cursor chat, Windsurf chat** — any tool that doesn't auto-load `CLAUDE.md`.

**Tip:** If you can switch to **Claude Code** (CLI), you skip this step entirely — Claude Code auto-loads the full 1,100-line `CLAUDE.md`.

---

## Global Setup (Use Salesforce MCP in Any Project)

If you want the Salesforce MCP available everywhere (not just inside this repo), add it to your global Claude Code config:

```bash
# Add to ~/.claude/settings.json (global, works in any directory)
claude mcp add salesforce -g -- npx -y @salesforce/mcp --orgs ameyo --toolsets orgs,data,metadata,users --allow-non-ga-tools
```

Or manually add to `~/.claude/settings.json`:
```json
{
  "mcpServers": {
    "salesforce": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "@salesforce/mcp",
        "--orgs", "ameyo",
        "--toolsets", "orgs,data,metadata,users",
        "--allow-non-ga-tools"
      ]
    }
  }
}
```

After this, you can query Salesforce from any Claude Code session without being inside this repo.

---

## What You Can Do

Once connected, ask questions in natural language:

**Revenue & Bookings:**
- "What was our total revenue in March 2026?"
- "Who booked the highest MRR this quarter?"
- "Show revenue by sector for FY26"

**Pipeline & Deals:**
- "Show me all open opportunities stuck for more than a month"
- "What's our pipeline by stage?"
- "List top 10 deals by Net New INR"

**Support Tickets:**
- "How many Platform support tickets were raised this month?"
- "Show me all high-priority open cases"
- "Which queue has the most pending cases?"

**Accounts & Contacts:**
- "List all accounts with revenue growth > 20%"
- "Which accounts are churned (Churned_Day > 0)?"
- "Show me accounts in the BFSI sector"

**Tip:** The `CLAUDE.md` file in this repo contains detailed field mappings (1,100+ lines) for Revenue, Opportunity, Case, Account, and Lead objects. **Claude Code / Cursor / Windsurf read this automatically** and build correct SOQL queries. **Claude Desktop, ChatGPT, and VS Code Copilot do NOT auto-load it** — paste [`EXOTEL_FIELD_GUIDE.md`](./EXOTEL_FIELD_GUIDE.md) (compact 20k-char version) into their project instructions instead.

---

## Field Mapping Reference

This repo includes comprehensive field mappings in `CLAUDE.md` (1,100+ lines). Key mappings:

| Domain | Object | Key Fields |
|--------|--------|------------|
| Revenue | `accounts_revenue__c` | `Revenue_Booked_Amount__c`, `Revenue_Booked_On__c`, `Cluster__c`, `GP__c`, `SKU__c` |
| Bookings | `Opportunity` | `Net_New_INR__c`, `B_Deal_Date__c`, `StageName`, `Account_Cluster__c` |
| Support | `Case` | `CaseNumber`, `Status`, `Priority`, `Queue__c`, `Issue_Category__c`, `Product_Type__c` |
| Accounts | `Account` | `AccountSid__c`, `Customer_Health__c`, `Churned_Day__c`, `Cluster__c` |
| Pipeline | `Opportunity` | Stages: Prospect through Order (see CLAUDE.md for full mapping) |

**Slang/abbreviations are auto-mapped:** "Dom" = Domestic Enterprise, "BI" = Banking and Insurance, "ECC" = Contact Centre, etc. See `CLAUDE.md` for the full dictionary.

---

## Ask Salesforce - AI-Powered Query Assistant (LWC)

This repo also contains the **Ask Salesforce** Lightning Web Component -- an AI-powered natural language CRM query assistant built directly into Salesforce.

### Architecture

- **Frontend**: `askSalesforce` LWC with chat UI and session memory (10 exchanges)
- **Backend**: `AiSalesAssistantController` with 3-attempt self-correction retry
- **AI Engine**: Claude Sonnet 4.6 via `ClaudeApiService`
- **Query Safety**: `SoqlSanitizer` with 6 auto-fix rules and GROUP BY validation
- **Field Catalog**: 1,454+ fields across Opportunity, Case, Account, Lead

### Stress Test Results

75 real-world business questions tested against production data:

| Metric | Result |
|--------|--------|
| Success Rate | **94.7%** (54/57 API-reachable) |
| Retry Recovery | **100%** (17/17 recovered) |
| Unit Tests | **63 passing** (41 sanitizer + 22 other) |
| Avg Response Time | ~21 seconds |

### Key Files

| File | Description |
|------|-------------|
| `AiSalesAssistantController.cls` | Main controller with AI orchestration |
| `SoqlSanitizer.cls` | SOQL validation and 6 auto-fix rules |
| `ClaudeApiService.cls` | Anthropic Claude API integration |
| `StressTestRunner.cls` | 75-question stress test suite |
| `askSalesforce/` (LWC) | Chat UI with markdown rendering |
| `Ask_Salesforce_Report.docx` | Full technical report |

---

## Salesforce Org Details

- **Org**: Exotel (alias: `ameyo`)
- **URL**: https://ameyo.my.salesforce.com
- **MCP Toolsets**: `orgs` (org info), `data` (SOQL queries), `metadata` (object schemas), `users` (user management)

---

## Troubleshooting

### "No Salesforce org found" / MCP server fails to start
Re-authenticate:
```bash
sf org login web -a ameyo -r https://ameyo.my.salesforce.com
```
Then verify: `sf org list` should show `ameyo` as Connected.

### "npx timeout" or slow startup
The first run downloads the MCP package via npx, which can be slow. Fix by installing globally:
```bash
npm install -g @salesforce/mcp
```
Then you can also update your config to use the direct binary path (faster startup):
```bash
# Find the exact path
which sf-mcp-server
```
```json
{
  "mcpServers": {
    "salesforce": {
      "type": "stdio",
      "command": "<full-path-to-sf-mcp-server>",
      "args": [
        "--orgs", "ameyo",
        "--toolsets", "orgs,data,metadata,users",
        "--allow-non-ga-tools"
      ],
      "env": {
        "PATH": "<your-shell-PATH>",
        "NODE_NO_WARNINGS": "1"
      }
    }
  }
}
```

### "node: command not found" / "env: node: No such file or directory"
Claude Desktop can't find `node` because it doesn't inherit your shell PATH. Common with **nvm**, **volta**, and **fnm** users.

Fix: find where node lives and add it to your config's `env.PATH`:
```bash
dirname $(which node)
# Example: /Users/you/.nvm/versions/node/v24.11.1/bin
```
Add that directory to the `"PATH"` value in your Claude Desktop config's `env` block. Or use the full `echo $PATH` approach from the Claude Desktop Setup section above.

### "Permission denied" or "INSUFFICIENT_ACCESS" errors
Your Salesforce profile may not have API access or access to specific objects. Contact your Salesforce admin or Shivanand.

### Token expired (401 errors after a few days)
SF tokens expire. Re-authenticate:
```bash
sf org login web -a ameyo -r https://ameyo.my.salesforce.com
```

### npm cache corruption
If you get `ENOENT` or module not found errors:
```bash
npm cache clean --force
npm install -g @salesforce/cli
```

---

## Security

- No credentials are stored in this repo
- Each user authenticates independently via Salesforce OAuth
- Tokens are stored in your local system keychain (`~/.sfdx/`)
- Data access respects your Salesforce profile permissions
- All queries are read-only SOQL (no data modification)
- The MCP server runs locally on your machine, not on a remote server
