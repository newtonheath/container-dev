# Fedora 44 dev container — Cline (headless CLI + VS Code remote extension)
# Auth: Anthropic API key or OpenAI-compatible endpoint (e.g. LAN server)
FROM container-dev-base:latest

# --- Cline ---------------------------------------------------------------
RUN npm install -g cline

# Pre-create config dirs so the entrypoint's bind-mount copy targets exist
RUN mkdir -p /root/.cline/data

# --- Cline VS Code extension (baked in for Remote-SSH auto-install) ------
# VS Code Remote-SSH doesn't push local extensions to a fresh remote host by
# default, so each new container would otherwise need "Install in SSH: ..."
# clicked by hand. Instead we stage the .vsix in the image; entrypoint.sh
# installs it into ~/.vscode-server once the VS Code Server appears there
# (first Remote-SSH connection), so it's present without any manual step.
RUN mkdir -p /opt/vsix && \
    VSIX_URL=$(curl -fsSL https://open-vsx.org/api/saoudrizwan/claude-dev/latest | \
      python3 -c 'import json,sys; print(json.load(sys.stdin)["files"]["download"])') && \
    curl -fsSL -o /opt/vsix/cline.vsix "$VSIX_URL"

# --- workspace -----------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
