FROM ubuntu:rolling@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        git-lfs \
        git-svn \
        python3 \
        subversion \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Clone external test repo requested by user.
RUN git clone https://github.com/Contrast-Security-OSS/cargo-cats /workspace/cargo-cats

# Keep only file contents from cargo-cats, drop git metadata.
RUN rm -rf /workspace/cargo-cats/.git /workspace/cargo-cats/.gitmodules /workspace/cargo-cats/.github /workspace/cargo-cats/.gitignore

# Copy this project into the container for local testing.
COPY . /workspace/svn-to-github-migration

WORKDIR /workspace

# Start an interactive shell when the container launches.
CMD ["bash"]