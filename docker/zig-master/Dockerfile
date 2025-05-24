FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    wget \
    xz-utils \
    git \
    curl \
    ca-certificates \
    build-essential \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Zig master
RUN wget -q https://ziglang.org/builds/zig-linux-x86_64-0.15.0-dev.621+a63f7875f.tar.xz \
    && tar -xf zig-linux-x86_64-0.15.0-dev.621+a63f7875f.tar.xz \
    && mv zig-linux-x86_64-0.15.0-dev.621+a63f7875f /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm zig-linux-x86_64-0.15.0-dev.621+a63f7875f.tar.xz

# Create working directory
WORKDIR /workspace

# Copy build script
COPY build.sh /usr/local/bin/build.sh
RUN chmod +x /usr/local/bin/build.sh

CMD ["/usr/local/bin/build.sh"] 