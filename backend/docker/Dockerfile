FROM ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    scrot \
    && rm -rf /var/lib/apt/lists/*

# Install Chromium via playwright (snap chromium doesn't work in Docker)
# Run as computeruse so the binary lands in their home dir
USER computeruse
RUN pip install playwright && playwright install chromium
USER root
RUN playwright install-deps chromium 2>/dev/null || true && \
    ln -sf $(find /home/computeruse/.cache/ms-playwright -name "chrome" -path "*/chrome-linux/chrome" -type f | head -1) /usr/local/bin/chromium

COPY relay_tool_runner.py /relay_tool_runner.py
RUN chmod +x /relay_tool_runner.py

COPY sequoia.jpg /usr/share/wallpaper.jpg

# Create chromium alias so "chromium" works from any context
RUN ln -sf $(find /home/computeruse/.cache/ms-playwright -name "chrome" -path "*/chrome-linux/chrome" -type f | head -1) /usr/local/bin/chromium && \
    chmod 755 /usr/local/bin/chromium

# Set US keyboard layout on X startup
RUN echo 'setxkbmap us' >> /home/computeruse/.bashrc

USER computeruse
