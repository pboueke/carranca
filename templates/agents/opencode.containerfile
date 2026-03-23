# OpenCode CLI
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path && \
    mv /root/.opencode/bin/opencode /usr/local/bin/opencode && \
    chmod 0755 /usr/local/bin/opencode && \
    rm -rf /root/.opencode
