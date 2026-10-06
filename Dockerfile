# Stage 1: Install AWS CLI v2 (keeps unzip out of the final image)
FROM debian:trixie-slim AS aws-builder
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip \
  && set -eux \
  && ARCH="${TARGETARCH:-$(dpkg --print-architecture)}" \
  && case "$ARCH" in \
       amd64) AWS_ARCH="x86_64" ;; \
       arm64) AWS_ARCH="aarch64" ;; \
       *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
     esac \
  && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" \
       -o /tmp/awscliv2.zip \
  && cd /tmp && unzip -q awscliv2.zip \
  && /tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin

# Stage 2: Runtime image
FROM debian:trixie-slim

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    PIP_BREAK_SYSTEM_PACKAGES=1

# Install runtime packages, Docker CLI, and GitHub CLI, then remove build-only deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release less git \
      python3 python3-pip python3-venv bubblewrap ripgrep \
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
      https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli docker-compose-plugin gh \
  && apt-get purge -y --auto-remove gnupg lsb-release \
  && rm -rf /var/lib/apt/lists/*

# Non-root user. No sudo, no sudoers entry: there is deliberately no path to
# root inside this container.
RUN useradd -ms /bin/bash dev && \
  mkdir -p /home/dev/.config /home/dev/.local/bin && \
  chown -R dev:dev /home/dev/.config /home/dev/.local

# Copy AWS CLI from builder stage. The installer's /usr/local/bin entries are
# symlinks; COPY would dereference them into standalone binaries that can't find
# their bundled libpython, so recreate the symlinks here instead.
COPY --from=aws-builder /usr/local/aws-cli /usr/local/aws-cli
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws && \
    ln -s /usr/local/aws-cli/v2/current/bin/aws_completer /usr/local/bin/aws_completer

# Strip setuid/setgid bits (su, mount, passwd, ...). The launcher also sets
# no-new-privileges, so this is belt-and-braces: no binary can escalate.
RUN find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod a-s {} +

# Entrypoint and sandbox self-test (installed before dropping to dev)
COPY start-claude /usr/local/bin/start-claude
COPY sandbox-check /usr/local/bin/sandbox-check
RUN chmod +x /usr/local/bin/start-claude /usr/local/bin/sandbox-check

# Everything from here on runs as dev; the image never switches back to root.
USER dev
ENV HOME=/home/dev
WORKDIR /work

# Install Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash

# Install MCP Python package for pdb_mcp_server (separate layer for caching)
RUN python3 -m pip install --user --no-cache-dir mcp

# Copy container plugin (subagents, MCP servers, and config)
COPY --chown=dev:dev container-plugin /home/dev/container-plugin

# The Docker CLI talks to the proxy sidecar through a shared volume; the real
# daemon socket is never mounted into this container.
ENV DOCKER_HOST=unix:///run/docker-proxy/docker.sock

ENTRYPOINT ["/usr/local/bin/start-claude"]
