# Fedora 44 dev container — Pi (https://pi.dev)
# Auth: Anthropic API key, picked up directly from ANTHROPIC_API_KEY
FROM container-dev-base:latest

# --- Pi ----------------------------------------------------------------
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# Pre-create config dir so the entrypoint's config-seeding target exists
RUN mkdir -p /root/.pi/agent

# --- workspace -----------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
