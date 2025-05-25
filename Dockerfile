# Multi-stage build for Zig Package Checker
FROM alpine:3.19 AS builder

# Install build dependencies
RUN apk add --no-cache \
    wget \
    xz \
    git \
    curl \
    ca-certificates \
    build-base \
    musl-dev \
    linux-headers \
    sqlite \
    sqlite-dev

# Install Zig with architecture detection
ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        ARCH="aarch64"; \
    else \
        ARCH="x86_64"; \
    fi && \
    ZIG_VERSION="0.14.0" && \
    wget -q https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ARCH}-${ZIG_VERSION}.tar.xz \
    && tar -xf zig-linux-${ARCH}-${ZIG_VERSION}.tar.xz \
    && mv zig-linux-${ARCH}-${ZIG_VERSION} /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm zig-linux-${ARCH}-${ZIG_VERSION}.tar.xz

# Set working directory
WORKDIR /app

# Copy source code and dependencies
COPY build.zig build.zig.zon ./
COPY src/ ./src/
COPY libs/ ./libs/

# Set environment variables for C compilation
ENV C_INCLUDE_PATH=/usr/include
ENV CPATH=/usr/include

# Build the application
RUN zig build -Doptimize=Debug

# Production stage
FROM alpine:3.19

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    docker \
    docker-cli \
    git \
    curl \
    bash \
    sqlite \
    procps \
    coreutils

# Create app user for security and add to docker group
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup && \
    addgroup -g 999 -S docker && \
    adduser appuser docker

# Create necessary directories
RUN mkdir -p /app/templates /app/static /app/docker /app/data /tmp/build_results && \
    chown -R appuser:appgroup /app /tmp/build_results && \
    chmod 755 /app /tmp/build_results

# Copy built application from builder stage
COPY --from=builder /app/zig-out/bin/zig_pkg_checker /app/
COPY --chown=appuser:appgroup templates/ /app/templates/
COPY --chown=appuser:appgroup static/ /app/static/
COPY --chown=appuser:appgroup docker/ /app/docker/

# Set correct permissions for the binary
RUN chown appuser:appgroup /app/zig_pkg_checker && \
    chmod +x /app/zig_pkg_checker

# Set working directory
WORKDIR /app

# Keep as root for Docker and io_uring access
# USER appuser

# Expose port
EXPOSE 3001

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3001/api/health || exit 1

# Run the application
CMD ["./zig_pkg_checker"] 