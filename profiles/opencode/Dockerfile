# Fedora 44 dev container — OpenCode (https://opencode.ai)
# Auth: Anthropic API key (ANTHROPIC_API_KEY), passed through to opencode.json
FROM container-dev-base:latest

# --- OpenCode --------------------------------------------------------------
RUN npm install -g opencode-ai

# Pre-create config dir so the entrypoint's config-seeding target exists
RUN mkdir -p /root/.config/opencode

# --- workspace -----------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
