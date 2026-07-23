FROM debian:12

RUN apt-get update && apt-get install -y curl git bats coreutils && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.15.2
RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz && \
	cd /tmp && \
	tar -xvf zig.tar.xz && \
  mv zig-x86_64-linux-${ZIG_VERSION} /usr/local/zig && \
  ln -s /usr/local/zig/zig /usr/local/bin/zig

ENV PATH=/usr/local/zig:$PATH

WORKDIR /app

CMD ["zig"]
