# Stage 1: Build the Go bridge
FROM golang:1.23-bullseye AS bridge-builder

# Enable CGO for sqlite3 support (required by whatsmeow)
ENV CGO_ENABLED=1

WORKDIR /app/whatsapp-bridge
# Copy go.mod and go.sum if they exist (handling cases where they might be missing in some forks)
COPY whatsapp-bridge/go.mod* whatsapp-bridge/go.sum* ./
RUN if [ -f go.mod ]; then go mod download; fi

COPY whatsapp-bridge/ ./
RUN go build -o /app/whatsapp-bridge-bin main.go

# Stage 2: Final image
FROM python:3.11-slim-bullseye

# Install system dependencies
RUN apt-get update && apt-get install -y \
    ffmpeg \
    curl \
    sqlite3 \
    gcc \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install uv for efficient Python package management
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Set up working directory structure matching the code's expectations
WORKDIR /app
RUN mkdir -p /app/whatsapp-bridge /app/whatsapp-mcp-server

# Copy the Go bridge binary into its expected relative path
COPY --from=bridge-builder /app/whatsapp-bridge-bin /app/whatsapp-bridge/whatsapp-bridge-bin

# Copy Python MCP server files
COPY whatsapp-mcp-server/ /app/whatsapp-mcp-server/

# Install Python dependencies using uv
WORKDIR /app/whatsapp-mcp-server
RUN if [ -f pyproject.toml ]; then uv sync --frozen; fi

# Create an entrypoint script to manage both processes
WORKDIR /app
RUN echo '#!/bin/bash\n\
# Start Go bridge in the background, output to stderr\n\
# This ensures the QR code and logs do not interfere with MCP JSON-RPC on stdout\n\
cd /app/whatsapp-bridge\n\
./whatsapp-bridge-bin >&2 &\n\
\n\
# Wait for the bridge to initialize and create the SQLite DB\n\
sleep 5\n\
\n\
# Run the Python MCP server in the foreground\n\
cd /app/whatsapp-mcp-server\n\
exec uv run main.py' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# Persistence: Mount this directory to keep your WhatsApp session and chat history
VOLUME /app/whatsapp-bridge

# Ensure Python output is sent directly to the terminal
ENV PYTHONUNBUFFERED=1

# The MCP server communicates over stdio
ENTRYPOINT ["/app/entrypoint.sh"]
