# =============================================================================
# agent-room Dockerfile (Python)
# A local web console for managing Claude agent sessions.
#
# Build:
#   ./build_images.sh
#
# The runtime relies on mounting the host's ~/.claude/ settings for API
# credentials managed by cc-switch.  See docker-compose.yml for the full
# volume set.
# =============================================================================

FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    openssh-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 安装 Node.js（仅用于安装 claude-code 二进制，web 服务器本身是 Python）
COPY --from=node:20-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=node:20-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    npm install -g @anthropic-ai/claude-code && \
    rm -rf /root/.npm /tmp/*

# 拷贝 web 应用代码
COPY web/ /app
WORKDIR /app

# 默认端口（可通过 PORT 环境变量覆盖）
EXPOSE 6004

CMD ["python3", "server.py"]
