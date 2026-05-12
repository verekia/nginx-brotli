ARG ALPINE_VERSION=3.23.4
ARG NGINX_VERSION=1.30.0
ARG NGX_BROTLI_COMMIT=a71f9312c2deb28875acc7bacfdd5695a111aa53

# Builder

FROM alpine:${ALPINE_VERSION} AS builder

ARG NGINX_VERSION
ARG NGX_BROTLI_COMMIT

RUN apk add --no-cache \
    gcc g++ make cmake git wget \
    libc-dev linux-headers \
    openssl-dev pcre2-dev zlib-dev

WORKDIR /build

RUN git clone https://github.com/google/ngx_brotli.git \
    && cd ngx_brotli \
    && git checkout ${NGX_BROTLI_COMMIT} \
    && git submodule update --init --recursive

RUN cd ngx_brotli/deps/brotli \
    && mkdir out && cd out \
    && cmake -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_C_FLAGS="-Ofast -funroll-loops" \
        -DCMAKE_CXX_FLAGS="-Ofast -funroll-loops" \
        .. \
    && cmake --build . --config Release --target brotlienc -j"$(nproc)"

RUN wget -q https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz \
    && tar xzf nginx-${NGINX_VERSION}.tar.gz \
    && cd nginx-${NGINX_VERSION} \
    && ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-pcre-jit \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_gzip_static_module \
        --with-http_stub_status_module \
        --with-http_sub_module \
        --with-http_addition_module \
        --with-http_auth_request_module \
        --with-threads \
        --with-file-aio \
        --with-compat \
        --with-cc-opt="-Os" \
        --with-ld-opt="-Wl,--as-needed -s" \
        --add-module=/build/ngx_brotli \
    && make -j"$(nproc)" \
    && make install \
    && strip /usr/sbin/nginx

# Runtime

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache pcre2 zlib openssl tzdata \
    && addgroup -S nginx \
    && adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx \
    && mkdir -p /var/cache/nginx /var/log/nginx /usr/share/nginx/html \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /etc/nginx /etc/nginx

RUN mkdir -p /etc/nginx/conf.d && printf '%s\n' \
    'user nginx;' \
    'worker_processes auto;' \
    '' \
    'error_log /var/log/nginx/error.log notice;' \
    'pid /var/run/nginx.pid;' \
    '' \
    'events {' \
    '    worker_connections 1024;' \
    '}' \
    '' \
    'http {' \
    '    include /etc/nginx/mime.types;' \
    '    default_type application/octet-stream;' \
    '' \
    '    log_format main '"'"'$remote_addr - $remote_user [$time_local] "$request" '"'"'' \
    '                    '"'"'$status $body_bytes_sent "$http_referer" '"'"'' \
    '                    '"'"'"$http_user_agent" "$http_x_forwarded_for"'"'"';' \
    '' \
    '    access_log /var/log/nginx/access.log main;' \
    '' \
    '    sendfile on;' \
    '    tcp_nopush on;' \
    '    keepalive_timeout 65;' \
    '' \
    '    include /etc/nginx/conf.d/*.conf;' \
    '}' \
    > /etc/nginx/nginx.conf

EXPOSE 80
STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
