FROM alpine:3.23

RUN apk add curl git bats

ARG ZIG_VERSION=0.15.2
RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz && \
	cd /tmp && \
	tar -xvf zig.tar.xz && \
  mv zig-x86_64-linux-${ZIG_VERSION} /usr/local/zig && \
  ln -s /usr/local/zig/zig /usr/local/bin/zig

ENV PATH=/usr/local/zig:$PATH

WORKDIR /app

COPY . /app/

RUN zig build

CMD ["zig", "build"]
