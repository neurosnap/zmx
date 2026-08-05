FROM debian:12

RUN apt-get update && apt-get install -y curl git bats coreutils && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
# `uname -m` already reports the names zig uses in its tarballs (x86_64,
# aarch64), so it needs no mapping. Hardcoding x86_64 here meant the image ran
# under emulation on an arm64 host, where `zig build` dies with
# "rosetta error: bss_size overflow".
RUN ARCH="$(uname -m)" && \
	case "$ARCH" in \
	  x86_64|aarch64) ;; \
	  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
	esac && \
	curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz && \
	cd /tmp && \
	tar -xf zig.tar.xz && \
	mv zig-${ARCH}-linux-${ZIG_VERSION} /usr/local/zig && \
	ln -s /usr/local/zig/zig /usr/local/bin/zig && \
	rm -f /tmp/zig.tar.xz

ENV PATH=/usr/local/zig:$PATH

WORKDIR /app

CMD ["zig"]
