# Fedora 44 dev container — Cline (headless CLI + VS Code remote extension)
# Auth: Anthropic API key or OpenAI-compatible endpoint (e.g. LAN server)
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
        hostname \
        openssh-server && \
    dnf clean all

# --- SSH server ----------------------------------------------------------
RUN ssh-keygen -A && \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
    passwd -d root
COPY sshd_config /etc/ssh/sshd_config

# --- Cline ---------------------------------------------------------------
RUN npm install -g cline

# Pre-create config dirs so the entrypoint's bind-mount copy targets exist
RUN mkdir -p /root/.cline/data

# --- workspace -----------------------------------------------------------
WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]
