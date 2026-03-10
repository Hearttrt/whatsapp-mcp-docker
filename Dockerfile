# Stage 1: Build the Go bridge
FROM golang:1.24-bullseye AS bridge-builder

# 安装构建 CGO 项目必备的工具
RUN apt-get update && apt-get install -y build-essential gcc libc6-dev

# 开启 CGO
ENV CGO_ENABLED=1
# 设置代理以防网络问题（Actions 默认环境通常不需要，但添加更稳妥）
ENV GOPROXY=https://proxy.golang.org,direct

WORKDIR /app/whatsapp-bridge

# 1. 复制所有文件
COPY whatsapp-bridge/ .

# 2. 这里的逻辑做了调整：
# - 如果没有 go.mod，则初始化
# - 直接运行 go build，-v 参数会打印详细的构建过程，方便报错时排查
RUN [ -f go.mod ] || go mod init whatsapp-bridge && \
    go mod tidy && \
    go build -v -o /app/whatsapp-bridge-bin main.go

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
