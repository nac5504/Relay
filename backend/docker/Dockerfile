FROM ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    scrot \
    && rm -rf /var/lib/apt/lists/*

# Install real Chromium via playwright (snap chromium doesn't work in Docker)
RUN pip install playwright && \
    playwright install chromium && \
    playwright install-deps chromium && \
    # Symlink so "chromium" command works from anywhere
    ln -sf $(find /root/.cache/ms-playwright -name "chrome" -type f | head -1) /usr/local/bin/chromium

COPY relay_tool_runner.py /relay_tool_runner.py
RUN chmod +x /relay_tool_runner.py

USER computeruse
