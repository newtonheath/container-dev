# Fedora 44 dev container — Claude Code (unified, auth auto-detected)
# Supports: Vertex AI, API key, and Browser OAuth
FROM docker.io/library/fedora:44

# --- base tooling -------------------------------------------------------
RUN dnf -y update && \
    dnf -y install \
        git \
        ripgrep \
        curl \
        wget \
        tar \
        gzip \
        which \
        sudo \
        ca-certificates \
        nodejs \
        npm \
        python3 \
        python3-pip \
        gcc \
        gcc-c++ \
        make \
        less \
        vim \
        nano \
        procps-ng \
        iputils \
        iproute \
        bind-utils \
        openssh-clients \
        jq \
        unzip \
        zip \
        file \
        tree \
        rsync \
        gnupg2 \
        pkgconf-pkg-config \
        cmake \
        htop \
        openssh-server && \
    dnf clean all

# --- SSH server ----------------------------------------------------------
RUN ssh-keygen -A && \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
    passwd -d root
COPY sshd_config /etc/ssh/sshd_config

# --- Claude Code ---------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code

# Pre-create the mountpoint parent — file-level bind mounts under /root/.claude
# need this directory to exist in the image before the container starts.
RUN mkdir -p /root/.claude

# --- Claude Code VS Code extension (baked in for Remote-SSH auto-install) ---
# VS Code Remote-SSH doesn't push local extensions to a fresh remote host by
# default, so each new container would otherwise need "Install in SSH: ..."
# clicked by hand — and a transient container gets destroyed and recreated on
# every workspace switch, wiping ~/.vscode-server each time. Instead we stage
# the .vsix in the image; entrypoint.sh installs it into ~/.vscode-server once
# the VS Code Server appears there (first Remote-SSH connection), so it's
# present without any manual step, on every container regardless of type.
#
# Unlike Cline's extension, this one ships a separate .vsix per OS/arch (it
# bundles native binaries), so the platform must match this image's actual
# architecture, not just be "latest".
RUN mkdir -p /opt/vsix && \
    ARCH="$(uname -m)" && \
    case "$ARCH" in \
      x86_64)  VSIX_PLATFORM=linux-x64 ;; \
      aarch64) VSIX_PLATFORM=linux-arm64 ;; \
      *) echo "Unsupported architecture for Claude Code VS Code extension: $ARCH" >&2; exit 1 ;; \
    esac && \
    VSIX_URL=$(curl -fsSL https://open-vsx.org/api/Anthropic/claude-code/latest | \
      python3 -c "import json,sys; print(json.load(sys.stdin)['downloads']['$VSIX_PLATFORM'])") && \
    curl -fsSL -o /opt/vsix/claude-code.vsix "$VSIX_URL"

# --- workspace -----------------------------------------------------------
WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]
