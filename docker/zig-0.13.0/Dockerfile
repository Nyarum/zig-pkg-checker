FROM alpine:3.19

# Install dependencies
RUN apk add --no-cache \
    wget \
    xz \
    git \
    curl \
    ca-certificates \
    build-base \
    jq \
    procps \
    bash \
    coreutils

# Install Zig 0.13.0 with architecture detection
ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        ARCH="aarch64"; \
    else \
        ARCH="x86_64"; \
    fi && \
    wget -q https://ziglang.org/download/0.13.0/zig-linux-${ARCH}-0.13.0.tar.xz \
    && tar -xf zig-linux-${ARCH}-0.13.0.tar.xz \
    && mv zig-linux-${ARCH}-0.13.0 /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm zig-linux-${ARCH}-0.13.0.tar.xz

# Create working directory
WORKDIR /workspace

# Copy build script
COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

CMD ["/usr/local/bin/build.sh"] 