ARG PG_VERSION=15.6
ARG PG_MAJOR_VERSION=15
ARG VERSION=custom

FROM golang:1.20

WORKDIR /go/src/github.com/fly-apps/fly-postgres
COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -v -o /fly/bin/event_handler ./cmd/event_handler
RUN CGO_ENABLED=0 GOOS=linux go build -v -o /fly/bin/failover_validation ./cmd/failover_validation
RUN CGO_ENABLED=0 GOOS=linux go build -v -o /fly/bin/pg_unregister ./cmd/pg_unregister
RUN CGO_ENABLED=0 GOOS=linux go build -v -o /fly/bin/start_monitor ./cmd/monitor
RUN CGO_ENABLED=0 GOOS=linux go build -v -o /fly/bin/start_admin_server ./cmd/admin_server
RUN CGO_ENABLED=0 GOOS=linux go build -v -o /fly/bin/start ./cmd/start

COPY ./bin/* /fly/bin/

FROM wrouesnel/postgres_exporter:latest AS postgres_exporter
FROM postgres:${PG_VERSION} as base
ENV PGDATA=/data/postgresql
ENV PGPASSFILE=/data/.pgpass
ARG VERSION
ARG PG_MAJOR_VERSION
ARG POSTGIS_MAJOR=3
ARG HAPROXY_VERSION=2.8

LABEL fly.app_role=postgres_cluster
LABEL fly.version=${VERSION}
LABEL fly.pg-version=${PG_VERSION}
LABEL fly.pg-manager=repmgr

####################
# Extension: pgx_ulid
####################
FROM base as pgx_ulid

# Download package archive
ARG pgx_ulid_release
ADD "https://github.com/pksunkara/pgx_ulid/releases/download/v${pgx_ulid_release}/pgx_ulid-v${pgx_ulid_release}-pg${postgresql_major}-${TARGETARCH}-linux-gnu.deb" \
    /tmp/pgx_ulid.deb

####################
# Collect extension packages
####################
FROM scratch as extensions
COPY --from=pgx_ulid /tmp/*.deb /tmp/

####################
# Build final image
####################
FROM base as production

# Setup extensions
COPY --from=extensions /tmp /tmp

RUN apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates iproute2 curl bash dnsutils vim socat procps ssh gnupg rsync barman-cli barman barman-cli-cloud cron \
    && apt autoremove -y

# Repmgr
RUN curl -L https://launchpad.net/ubuntu/+archive/primary/+files/postgresql-${PG_MAJOR_VERSION}-repmgr_5.3.3-2_amd64.deb -o postgresql-${PG_MAJOR_VERSION}-repmgr_5.3.3-2_amd64.deb

RUN apt-get update && \
    apt-get install -y ./postgresql-${PG_MAJOR_VERSION}-repmgr_5.3.3-2_amd64.deb \
    && rm ./postgresql-${PG_MAJOR_VERSION}-repmgr_5.3.3-2_amd64.deb

# PostGIS
RUN apt-get update && apt-get install --no-install-recommends -y \
    postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR \
    postgresql-$PG_MAJOR-postgis-$POSTGIS_MAJOR-scripts


RUN apt-get update && apt-get install -y --no-install-recommends \
    /tmp/*.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# Haproxy
RUN curl https://haproxy.debian.net/bernat.debian.org.gpg \
    | gpg --dearmor > /usr/share/keyrings/haproxy.debian.net.gpg

RUN echo deb "[signed-by=/usr/share/keyrings/haproxy.debian.net.gpg]" \
    http://haproxy.debian.net bookworm-backports-${HAPROXY_VERSION} main \
    > /etc/apt/sources.list.d/haproxy.list

RUN apt-get update && apt-get install --no-install-recommends -y \
    haproxy=$HAPROXY_VERSION.\* \
    && apt autoremove -y

COPY --from=0 /fly/bin/* /usr/local/bin
COPY --from=postgres_exporter /postgres_exporter /usr/local/bin/

ADD /config/* /fly/
RUN mkdir -p /run/haproxy/
RUN usermod -d /data postgres

EXPOSE 5432

CMD ["start"]
