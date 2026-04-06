FROM ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    scrot \
    && rm -rf /var/lib/apt/lists/*

# Install Chromium via playwright (snap chromium doesn't work in Docker)
USER computeruse
RUN pip install playwright && playwright install chromium
USER root
RUN playwright install-deps chromium 2>/dev/null || true

COPY relay_tool_runner.py /relay_tool_runner.py
RUN chmod +x /relay_tool_runner.py

COPY sequoia.jpg /usr/share/wallpaper.jpg

# Create chromium symlink + startup script that re-creates it on boot
RUN CHROME_BIN=$(find /home/computeruse/.cache/ms-playwright -name "chrome" -path "*/chrome-linux/chrome" -type f | head -1) && \
    ln -sf "$CHROME_BIN" /usr/local/bin/chromium && \
    chmod 755 /usr/local/bin/chromium && \
    echo '#!/bin/bash' > /usr/local/bin/setup-chromium.sh && \
    echo 'CHROME=$(find /home/computeruse/.cache/ms-playwright -name "chrome" -path "*/chrome-linux/chrome" -type f 2>/dev/null | head -1)' >> /usr/local/bin/setup-chromium.sh && \
    echo '[ -n "$CHROME" ] && ln -sf "$CHROME" /usr/local/bin/chromium && chmod 755 /usr/local/bin/chromium' >> /usr/local/bin/setup-chromium.sh && \
    echo 'DISPLAY=:1 setxkbmap us 2>/dev/null || true' >> /usr/local/bin/setup-chromium.sh && \
    chmod +x /usr/local/bin/setup-chromium.sh

# Set US keyboard layout on X startup
RUN echo 'setxkbmap us' >> /home/computeruse/.bashrc

USER computeruse
