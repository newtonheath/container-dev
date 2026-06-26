# Fedora 44 dev container — Claude Code via Vertex AI
# Designed for VS Code Remote-SSH: sshd runs in foreground, workspace at /workspace.
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

# --- gcloud CLI ----------------------------------------------------------
RUN curl -fsSL https://sdk.cloud.google.com > /tmp/install-gcloud.sh && \
    bash /tmp/install-gcloud.sh --disable-prompts --install-dir=/opt && \
    rm /tmp/install-gcloud.sh
ENV PATH="/opt/google-cloud-sdk/bin:${PATH}"

# --- Claude Code ---------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code

ENV CLAUDE_CODE_USE_VERTEX=1

# --- workspace -----------------------------------------------------------
WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]
