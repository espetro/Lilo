#!/bin/bash
# Starts Xvfb and the MCP server (stdio): an agent's MCP client launches this
# container with the socket piped through, and speaks MCP on stdin/stdout.
set -e

Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
XVFB_PID=$!
trap 'kill $XVFB_PID 2>/dev/null || true' EXIT

# WebKitGTK's renderer needs a moment to find the display.
for _ in $(seq 1 50); do
  xdpyinfo -display :99 >/dev/null 2>&1 && break
  sleep 0.1
done

exec python3 /app/container/linux/mcp_server.py
