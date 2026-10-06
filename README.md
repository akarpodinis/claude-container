# Claude Code Dev Container

A portable Docker-based development environment for running
[Claude Code](https://claude.ai/claude-code) safely in YOLO mode. This container
provides a consistent, isolated environment with Claude Code, AWS and GitHub CLIs,
and Docker tooling pre-installed.

## Features

- **Claude Code CLI** - Latest version installed and ready to use
- **AWS CLI v2** - For AWS Bedrock integration and other AWS operations
- **Docker + Docker Compose** - Filtered Docker access via socket proxy
- **GitHub CLI (`gh`)** - Create pull requests, manage issues, and interact with GitHub
- **Python 3 + MCP** - Python debugging support with pre-configured Pdb MCP server
- **Non-root execution** - Runs as unprivileged `dev` user with no sudo and all capabilities dropped
- **Volume mounting** - Seamlessly access your host repositories
- **Isolated Claude state** - Container sessions keep their own config under `~/.claude-container`, separate from your host `~/.claude`
- **Sandbox self-test** - `claude-container sandbox-check` verifies the boundary from the inside

## Prerequisites

- Docker installed on your host machine
- (Optional) AWS credentials configured in `~/.aws/` for Bedrock usage
- (Optional) `CLAUDE_GITHUB_TOKEN` env var or `gh auth login` for PR/issue workflows

## Quick Start

Clone or download this repo, `cd` into it, and run `make install`. This builds the agent image and the proxy sidecar image, then installs `claude-container` into `~/.local/bin`. If `~/.local/bin` is not already on your `PATH`, the install step prints a reminder.

Run `make test` to execute the proxy unit tests and then launch a real session that checks the sandbox boundary from the inside.

## Usage

### Basic usage

```bash
# Launch Claude Code in current directory
claude-container

# Pass additional arguments to Claude (default model is opus)
claude-container --model sonnet

# Show launcher help instead of CLI help
claude-container --container-help

# Run arbitrary commands in the container
claude-container bash
claude-container aws s3 ls

# Verify the sandbox boundary
claude-container sandbox-check
```

### Authentication

The container does **not** use your host `~/.claude` or `~/.claude.json`. It keeps
its own state under `~/.claude-container/` (override with `CLAUDE_CONTAINER_HOME`).
The first time you launch, sign in to Claude Code inside the container; the
credentials persist in that directory for later sessions.

Keeping the two separate means anything the agent writes to its own config
(settings, hooks, memory) cannot affect Claude Code sessions on your host.

### Environment Variables

The launcher script passes through these environment variables from your host if set:

- **`AWS_PROFILE`** - AWS profile to use (from `~/.aws/config`)
- **`AWS_REGION`** - AWS region for API calls
- **`CLAUDE_CODE_USE_BEDROCK`** - Set to `1` to use AWS Bedrock instead of Anthropic API
- **`CLAUDE_GITHUB_TOKEN`** - GitHub personal access token for `gh` CLI (passed as `GITHUB_TOKEN` inside the container)

Launcher settings:

- **`CLAUDE_CONTAINER_HOME`** - Host directory for container-only Claude state (default `~/.claude-container`)
- **`CLAUDE_CONTAINER_MEMORY`** - Memory limit for the agent container (default `8g`)
- **`CLAUDE_CONTAINER_PIDS`** - Process limit for the agent container (default `4096`)

Example:

```bash
# Set environment variables for your session
export AWS_PROFILE=myprofile
export AWS_REGION=us-west-2
export CLAUDE_CODE_USE_BEDROCK=1

# Launch container (will inherit the above settings)
claude-container
```

Or as a one-liner:

```bash
AWS_PROFILE=prod AWS_REGION=us-east-1 CLAUDE_CODE_USE_BEDROCK=1 claude-container
```

## What Gets Mounted

The `claude-container` script automatically mounts:

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| Current directory | Same path in container | rw | Your working repository |
| `~/.claude-container/claude` | `/home/dev/.claude` | rw | Container-only Claude settings and credentials |
| `~/.claude-container/claude.json` | `/home/dev/.claude.json` | rw | Container-only Claude config |
| `~/.aws` | `/home/dev/.aws` | ro | AWS credentials and config |
| `~/.gitconfig` | `/home/dev/.gitconfig` | ro | Git user identity and settings |
| `~/.config/gh` | `/home/dev/.config/gh` | ro | GitHub CLI auth tokens |
| per-session named volume | `/run/docker-proxy` | ro | Filtered Docker socket from the proxy sidecar |

The real Docker socket is never mounted into the agent container. It is mounted only
into the proxy sidecar (see below).

## Container Details

- **Base Image**: `debian:trixie-slim`
- **User**: `dev` (non-root, no sudo; the image contains no path to root)
- **Run flags**: `--cap-drop ALL --security-opt no-new-privileges --pids-limit --memory`
- **Working Directory**: Mirrors your host's current directory
- **Default Command**: `claude --dangerously-skip-permissions --model opus`. The entrypoint prints a note when it applies this default; pass `--model <name>` to override it.

## Docker Socket Proxy

A separate proxy container sits between Claude and the Docker daemon. It is the only
container that mounts the real socket. Instead of giving Claude unrestricted Docker
access, the proxy intercepts Docker API requests and enforces the following restrictions:

### What's Blocked

- **Privileged containers** (`--privileged`)
- **Dangerous capabilities** (`SYS_ADMIN`, `SYS_PTRACE`, `NET_ADMIN`, `SYS_RAWIO`, `SYS_MODULE`, `DAC_READ_SEARCH`, `ALL`)
- **Host PID namespace** (`--pid=host`)
- **Host network mode** (`--network=host`)

### Mount Restrictions

Bind mounts are restricted based on your working directory. Given a working directory of `/home/user/projects/my-app`:

| Path | Mode | Result |
|------|------|--------|
| `/home/user/projects/my-app/src` | rw | Allowed |
| `/home/user/projects/sibling` | ro | Allowed |
| `/home/user/projects/sibling` | rw | **Rejected** |
| `/etc/shadow` | any | **Rejected** |

The proxy passes `ALLOWED_MOUNT_BASE` (parent of cwd) and `ALLOWED_RW_BASE` (cwd) to control these restrictions.

### How It Works

1. The launcher creates a per-session named volume and starts the proxy sidecar
   (`claude-docker-proxy:latest`) with the host Docker socket mounted as
   `/var/run/docker-real.sock` and the volume mounted at `/run/docker-proxy`
2. The proxy listens on `/run/docker-proxy/docker.sock` inside that volume
3. The agent container mounts the same volume read-only and has `DOCKER_HOST`
   pointed at the proxy socket. It never sees the real socket, has no sudo, and
   runs with all capabilities dropped, so there is no route around the proxy
4. When the session ends the launcher removes the sidecar and the volume

### What the proxy does not cover

The proxy inspects container creation only. Other daemon operations pass through,
so the agent can still interact with containers already running on your host
daemon. Containers it creates are siblings of the agent container, not children.
This is a deliberate tradeoff to keep Docker Compose workflows working; if you do
not need Docker inside the session, the safest option is to not run the daemon.

## Troubleshooting

### Docker socket permissions

If you encounter Docker permission errors, ensure your user is in the `docker` group on the host:

```bash
sudo usermod -aG docker $USER
# Log out and back in for changes to take effect
```

### AWS credentials not found

Ensure your `~/.aws` directory exists and contains valid credentials:

```bash
aws configure
# or
aws configure --profile myprofile
```

### GitHub CLI not authenticated

There are two ways to authenticate `gh` inside the container:

**Option 1: Interactive login (recommended for personal use)**

```bash
# On your host machine
gh auth login
```

This stores credentials in `~/.config/gh/` which the container mounts automatically.

**Option 2: `CLAUDE_GITHUB_TOKEN` environment variable**

```bash
export CLAUDE_GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
claude-container
```

Required token scopes:

- **Classic PAT**: `repo` scope
- **Fine-grained PAT**: "Contents: Read and write" + "Pull requests: Read and write" on target repos

See GitHub docs for creating tokens: [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)

For more on the GitHub CLI: [About GitHub CLI](https://docs.github.com/en/github-cli/github-cli/about-github-cli)

### Claude Code asks you to sign in again

Container login state lives in `~/.claude-container/` on the host, not in your
host `~/.claude`, so signing in on the host does nothing for the container.
Sign in once inside the container and it persists across sessions and image
rebuilds. You will be asked to sign in again only if that directory is removed
or you point `CLAUDE_CONTAINER_HOME` somewhere new.

To skip the interactive login, place an API key in
`~/.claude-container/claude.json`:

```json
{
  "apiKey": "your-api-key-here"
}
```

## Container Plugin

The container includes a built-in plugin that provides additional subagents and MCP servers. This plugin **layers on top of** any configuration in the container's `~/.claude-container/claude/` directory without modifying it.

### How It Works

The container uses Claude Code's `--plugin-dir` flag to load `/home/dev/container-plugin`, which contains:

```
container-plugin/
├── .claude-plugin/
│   └── plugin.json           # Plugin manifest
├── pdb_mcp_server.py         # Pdb MCP server (loaded only when python-test-debugger is used)
└── agents/
    └── python-test-debugger.md  # Subagent definitions (includes inline MCP server config)
```

**Benefits of the plugin approach:**

- **Non-invasive** - Doesn't modify your `~/.claude/settings.json`
- **Layered** - Container tools add to (not replace) your existing config
- **Priority** - Your user-level agents take precedence over plugin agents if names conflict

### Included Subagents

#### python-test-debugger

A specialized agent for debugging failing Python tests interactively. Use it when:

- VCR/mocking doesn't seem to be working
- Tests fail after dependency updates
- Async/event loop errors occur
- Tests behave differently when run individually vs. in a suite

The agent has access to the `pdb` MCP server for interactive debugging.

#### memory-bank-analyzer

An agent that extracts project context from `memory_bank/` files before starting implementation work. Claude uses this agent **proactively** after you define a task to:

- Extract coding standards and style guidelines
- Identify architectural patterns and conventions
- Find project structure and organization principles
- Understand testing approaches and requirements

This ensures implementations follow your project's established patterns and standards.

### Included MCP Servers

#### pdb (Python Debugger)

`pdb_mcp_server.py` is embedded in the `container-plugin/` directory and is only started when the `python-test-debugger` skill is invoked — it does **not** run during normal Claude sessions. It provides:

- **`start_pdb_session`** - Start a Pdb session in a Docker Compose service
- **`send_pdb_command`** - Send commands (e.g., `n`, `s`, `p var`)
- **`stop_pdb_session`** - Stop the debugging session

### Adding Your Own Container Extensions

To add more subagents or MCP servers to the container:

1. Add subagent markdown files to `container-plugin/agents/`
2. To include an MCP server that loads only when a specific agent is used, place the server script in `container-plugin/` and define it inline in the agent's frontmatter:
   ```yaml
   mcpServers:
     my-server:
       command: python3
       args: ["/home/dev/container-plugin/my_server.py"]
   ```
3. Rebuild the container

Example subagent (`container-plugin/agents/my-agent.md`):

```markdown
---
name: my-agent
description: Description of when Claude should use this agent
tools: Read, Grep, Glob, Bash
model: inherit
---

You are a specialist in...
```
