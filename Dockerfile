FROM node:20-slim

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Common dev tools Claude might need
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

ENTRYPOINT ["claude"]
