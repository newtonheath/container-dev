# container-dev shared base image — Fedora 44 + common tooling + SSH server.
#
# Every profile Dockerfile builds `FROM container-dev-base:latest` instead of
# repeating this layer, so there's one source of truth for the base tooling
# (previously each profile duplicated this block independently, and drifted —
# e.g. `claude` was missing the `hostname` package the other three had).
#
# The leading `_` keeps this out of the profile list: `bin/create.sh`'s
# "Available profiles" listing filters `profiles/*` with `grep -v '^_'`, and
# it's never declared in config/container-dev.yaml's `profiles:` map, so it
# can't be selected as a profile name either.
FROM docker.io/library/fedora:44

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

RUN ssh-keygen -A && \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
    passwd -d root
COPY sshd_config /etc/ssh/sshd_config

WORKDIR /workspace
EXPOSE 22
