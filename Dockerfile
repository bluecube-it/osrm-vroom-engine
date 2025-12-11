ARG ALPINE_VERSION=3.23
ARG VROOM_VERSION=v1.14.0
ARG OSRM_VERSION=v6.0.0

FROM --platform=linux/amd64 ghcr.io/project-osrm/osrm-backend:${OSRM_VERSION} AS osrm_builder
FROM --platform=linux/amd64 ghcr.io/vroom-project/vroom-docker:${VROOM_VERSION} AS vroom_node_builder
FROM --platform=linux/amd64 alpine:${ALPINE_VERSION} AS vroom_builder
ARG VROOM_VERSION
RUN apk --update --no-cache add \
    asio-dev \
    build-base \
    cmake \
    git \
    glpk-dev \
    openssl-dev \
    pkgconf && \
    git clone --branch ${VROOM_VERSION} --single-branch --recurse-submodules https://github.com/VROOM-Project/vroom.git && \
    cd vroom && \
    make -C /vroom/src -j$(nproc)

FROM --platform=linux/amd64 alpine:${ALPINE_VERSION} AS runstage

COPY --from=osrm_builder /usr/local/bin/. /usr/local/bin
COPY --from=osrm_builder /opt/. /opt
COPY --from=vroom_builder /vroom/bin/vroom /usr/local/bin
COPY --from=vroom_node_builder /vroom-express/. /vroom-express
COPY vroom-config.yml /vroom-express/config.yml

RUN apk --update --no-cache add \
    boost-dev \
    curl \
    glpk-dev \
    libtbb-dev \
    lua5.4-dev \
    lz4-dev \
    nginx \
    nodejs \
    npm && \
    rm -rf /var/cache/apk/*

WORKDIR /app
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

HEALTHCHECK --start-period=10s CMD curl --fail -s http://127.0.0.1:8080/healthcheck || exit 1

EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]