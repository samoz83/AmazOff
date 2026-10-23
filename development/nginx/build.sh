#!/bin/sh
# Build tools/nginx/nginx: static ARMv7 nginx with OpenSSL linked in, from hash-checked sources.
# nginx's configure runs its test programs, so the build runs in an emulated ARM container,
# not with a cross compiler. Needs Docker with ARM emulation (Docker Desktop has it).
set -eu

NGINX_VERSION=1.30.6
NGINX_SHA256=3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/amazoff-nginx.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"
curl -fsSLO "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"
curl -fsSLO "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
printf '%s  %s\n%s  %s\n' \
  "$NGINX_SHA256" "nginx-$NGINX_VERSION.tar.gz" \
  "$OPENSSL_SHA256" "openssl-$OPENSSL_VERSION.tar.gz" | shasum -a 256 -c -

docker run --rm --platform linux/arm/v7 -v "$WORK_DIR:/src" \
  -e NGINX_VERSION="$NGINX_VERSION" -e OPENSSL_VERSION="$OPENSSL_VERSION" \
  debian:bookworm-slim sh -euc '
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends gcc make perl libc6-dev binutils >/dev/null
    # Build off the bind mount: Docker Desktop file sharing has returned corrupt reads under make -j.
    mkdir /build && cd /build
    tar xzf "/src/nginx-$NGINX_VERSION.tar.gz"
    tar xzf "/src/openssl-$OPENSSL_VERSION.tar.gz"
    cd "nginx-$NGINX_VERSION"
    # OpenSSL guesses -march=armv7-a from uname, which drops the FPU that armhf hard-float needs.
    ./configure --prefix=/opt/nginx-arm-static \
      --with-http_ssl_module --without-http_gzip_module --without-http_rewrite_module --without-pcre \
      --with-openssl="/build/openssl-$OPENSSL_VERSION" --with-openssl-opt="no-shared no-tests -march=armv7-a+fp" \
      --with-cc-opt="-O2 -fno-asynchronous-unwind-tables" \
      --with-ld-opt="-static -static-libgcc -Wl,--no-as-needed -ldl -lpthread"
    make -j"$(nproc)"
    strip -o /src/nginx objs/nginx
    /src/nginx -V
  '

cp "$WORK_DIR/nginx" "$ROOT_DIR/tools/nginx/nginx"
chmod 755 "$ROOT_DIR/tools/nginx/nginx"
shasum -a 256 "$ROOT_DIR/tools/nginx/nginx"
