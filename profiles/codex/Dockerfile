# Fedora 44 dev container — OpenAI Codex CLI
FROM container-dev-base:latest

# Install Codex using the official standalone installer. Keeping the installer
# home separate from the runtime CODEX_HOME prevents build-time state from
# being copied into containers or confused with a user's login cache.
RUN mkdir -p /opt/codex-installer-home /root/.codex && \
    curl -fsSL https://chatgpt.com/codex/install.sh | \
      CODEX_HOME=/opt/codex-installer-home \
      CODEX_INSTALL_DIR=/usr/local/bin \
      CODEX_NON_INTERACTIVE=1 sh && \
    codex --version

# --- OpenAI Codex VS Code extension ---------------------------------------
# The extension is installed into the remote VS Code Server by entrypoint.sh
# once Remote-SSH has downloaded that server into the new container. It ships
# native binaries, so select the VSIX for the image architecture.
RUN mkdir -p /opt/vsix && \
    ARCH="$(uname -m)" && \
    case "$ARCH" in \
      x86_64)  VSIX_PLATFORM=linux-x64 ;; \
      aarch64) VSIX_PLATFORM=linux-arm64 ;; \
      *) echo "Unsupported architecture for Codex VS Code extension: $ARCH" >&2; exit 1 ;; \
    esac && \
    VSIX_URL=$(curl -fsSL https://open-vsx.org/api/openai/chatgpt/latest | \
      python3 -c "import json,sys; print(json.load(sys.stdin)['downloads']['$VSIX_PLATFORM'])") && \
    curl -fsSL -o /opt/vsix/codex.vsix "$VSIX_URL"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
