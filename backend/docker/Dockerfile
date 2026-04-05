FROM ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    scrot \
    chromium \
    chromium-driver \
    && rm -rf /var/lib/apt/lists/*

# Set Chromium as the default browser
RUN update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/chromium 200 || true

USER computeruse
