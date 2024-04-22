FROM debian:bullseye-slim AS build
ARG USER=docker
ARG UID=1000
ARG GID=1000

RUN useradd -m ${USER} --uid=${UID}

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y wget gnupg
RUN echo "deb http://apt.postgresql.org/pub/repos/apt/ bullseye-pgdg main" >> /etc/apt/sources.list.d/pgdg.list
RUN wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -

RUN apt-get update && apt-get install -y git curl
RUN apt-get update && apt-get install -y gcc make build-essential libz-dev zlib1g-dev strace libssl-dev pkg-config

RUN apt-get update && apt-get install -y postgresql-15 postgresql-server-dev-15
RUN apt-get update && apt-get install -y ruby ruby-dev rubygems build-essential
RUN gem install dotenv -v 2.8.1
RUN gem install --no-document fpm

USER ${UID}:${GID}
WORKDIR /home/${USER}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash -s -- -y
ENV PATH="/home/${USER}/.cargo/bin:${PATH}"

RUN cargo install cargo-pgrx
RUN cargo pgrx init \
    --pg15=/usr/lib/postgresql/15/bin/pg_config

RUN mkdir -p accumulo-access-pg/src/
ADD accumulo_access_pg.control Cargo.toml Cargo.lock accumulo-access-pg/
ADD src/* accumulo-access-pg/src/

WORKDIR /home/${USER}/accumulo-access-pg
RUN cargo build --profile artifacts
RUN cargo pgrx package --profile artifacts -c /usr/bin/pg_config
RUN cd target/artifacts/accumulo_access_pg-pg15 && \
    fpm \
    -s dir \
    -t deb \
    -n accumuloaccess-pg15 \
    -v 0.1.0 \
    --deb-no-default-config-files \
    -p /tmp/accumulo_access_bullseye_pg15_0.1.0_amd64.deb \
    -a amd64 \
    .

FROM postgis/postgis:15-3.4 AS runtime

COPY --from=build /tmp/accumulo_access_bullseye_pg15_0.1.0_amd64.deb /tmp/
ADD 10_postgis.sh /docker-entrypoint-initdb.d/
RUN apt install -y /tmp/accumulo_access_bullseye_pg15_0.1.0_amd64.deb