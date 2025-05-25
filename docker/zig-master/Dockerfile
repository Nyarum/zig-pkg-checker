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

# Install Zig master with architecture detection
ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        ARCH="aarch64"; \
    else \
        ARCH="x86_64"; \
    fi && \
    ZIG_VERSION="0.15.0-dev.621+a63f7875f" && \
    wget -q https://ziglang.org/builds/zig-linux-${ARCH}-${ZIG_VERSION}.tar.xz \
    && tar -xf zig-linux-${ARCH}-${ZIG_VERSION}.tar.xz \
    && mv zig-linux-${ARCH}-${ZIG_VERSION} /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm zig-linux-${ARCH}-${ZIG_VERSION}.tar.xz

# Create working directory
WORKDIR /workspace

# Copy build script
COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

CMD ["/usr/local/bin/build.sh"] 