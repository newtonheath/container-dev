# Fedora 44 dev container for Claude Code CLI + opencode
# Apple `container` runs arm64 (aarch64) images on Apple silicon.
FROM docker.io/library/fedora:44

# --- base tooling -------------------------------------------------------
RUN dnf -y update && \
    dnf -y install \
        # --- already had ---
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
        # --- essential ---
        less \
        vim \
        nano \
        procps-ng \
        iputils \
        iproute \
        bind-utils \
        openssh-clients \
        jq \
        # --- worth it ---
        unzip \
        zip \
        file \
        tree \
        rsync \
        gnupg2 \
        pkgconf-pkg-config \
        cmake \
        # --- quality of life ---
        htop && \
    dnf clean all

# --- AI coding CLIs -----------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code

RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/root/.opencode/bin:${PATH}"

# --- workspace ----------------------------------------------------------
WORKDIR /workspace
CMD ["/bin/bash"]
