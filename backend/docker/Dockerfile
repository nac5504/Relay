FROM ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest

ARG APT_PACKAGES=""
ARG PIP_PACKAGES=""

USER root

# User-specified apt packages (passed via --build-arg at image build time)
RUN if [ -n "$APT_PACKAGES" ]; then \
      apt-get update && apt-get install -y $APT_PACKAGES && rm -rf /var/lib/apt/lists/*; \
    fi

# User-specified pip packages (passed via --build-arg at image build time)
RUN if [ -n "$PIP_PACKAGES" ]; then \
      pip install $PIP_PACKAGES; \
    fi

USER computeruse
