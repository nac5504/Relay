FROM ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    scrot \
    && rm -rf /var/lib/apt/lists/*

COPY relay_tool_runner.py /relay_tool_runner.py
RUN chmod +x /relay_tool_runner.py

USER computeruse
