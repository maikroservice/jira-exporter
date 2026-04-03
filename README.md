# jira-exporter

Export Jira issues to Markdown, HTML, or raw JSON from the command line.

Supports Jira Cloud and Jira Server/Data Center. Exports single issues, entire projects, agile boards, or any JQL query.

## Requirements

- `curl` (required)
- `jq` (recommended — falls back to basic grep/sed without it)
- `pandoc` (recommended — falls back to built-in HTML→Markdown converter without it)

## Installation

```bash
make install          # installs to /usr/local/bin/jira-export
make install-deps     # installs bats-core, jq, pandoc, shellcheck via brew
```

Or run directly:

```bash
./jira-export.sh --issue PROJ-1
```

## Configuration

Copy `.env.example` to `.jirarc` (or `~/.jirarc` for global config) and fill in your values:

```bash
cp .env.example .jirarc
```

The minimum required config for Jira Cloud:

```
JIRA_URL=https://yoursite.atlassian.net
JIRA_EMAIL=you@example.com
JIRA_TOKEN=your_api_token
```

Get your API token at <https://id.atlassian.com/manage-profile/security/api-tokens>.

**Config precedence** (highest to lowest): CLI flags → environment variables → `.jirarc` → `.env` → built-in defaults.

## Usage

```
Usage: jira-export.sh [OPTIONS]

Scope (one required):
  --issue <key|url>      Export a single issue
  --project <KEY>        Export all issues in a project
  --board <ID>           Export all issues from a board
  --jql <query>          Export issues matching a JQL query

Format:
  --format md|html|raw   Output format (default: md)

Output:
  --output <dir>         Output directory (default: ./export)
  --force                Overwrite existing files

Options:
  --comments             Include issue comments in output
  --list                 Dry run: print what would be exported, no files written
  --debug                Enable verbose debug output
  --help                 Show this help
```

## Examples

```bash
# Export a single issue
./jira-export.sh --issue PROJ-123

# Export a single issue including comments
./jira-export.sh --issue PROJ-123 --comments

# Export from a URL
./jira-export.sh --issue https://yoursite.atlassian.net/browse/PROJ-123

# Export all issues in a project
./jira-export.sh --project PROJ

# Export issues from an agile board
./jira-export.sh --board 42

# Export with a custom JQL query
./jira-export.sh --jql 'project = PROJ AND status = "In Progress"'

# Dry run — list what would be exported without writing files
./jira-export.sh --project PROJ --list

# Export to a custom directory in HTML format
./jira-export.sh --project PROJ --format html --output ./my-export

# Overwrite existing files
./jira-export.sh --project PROJ --force
```

## Output structure

```
export/
└── PROJ/
    ├── PROJ-1-fix-login-bug.md
    ├── PROJ-2-add-dark-mode.md
    └── ...
```

Each Markdown file contains the issue metadata table, description, and optionally comments:

```markdown
# [PROJ-1] Fix login bug

| Field    | Value      |
|----------|------------|
| Status   | In Progress |
| Type     | Bug        |
| Priority | High       |
| Assignee | John Doe   |
| Reporter | Jane Smith |
| Labels   | auth,login |
| Created  | 2024-01-15 |
| Updated  | 2024-01-20 |

## Description

Users cannot log in after the recent deployment.

## Comments

### John Doe — 2024-01-16

Investigating the root cause.
```

## Jira Server / Data Center

For Server/DC, set `JIRA_TYPE=server` and use username + password or a Personal Access Token:

```
JIRA_URL=https://jira.yourcompany.com
JIRA_TYPE=server
JIRA_USERNAME=youruser
JIRA_TOKEN=your_pat   # preferred
# JIRA_PASSWORD=yourpassword  # alternative
```

For PAT-only auth (no username):

```
JIRA_AUTH_TYPE=bearer
JIRA_TOKEN=your_pat
```

## Development

```bash
make test             # run all tests (unit + integration)
make test-unit        # unit tests only
make test-integration # integration tests only
make lint             # shellcheck all shell files
```

Tests use [bats-core](https://github.com/bats-core/bats-core) and a lightweight Python fixture server — no real Jira instance required.
