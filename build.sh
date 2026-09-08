#!/usr/bin/env bash
#
# Builds the .deb packages and the runtime Docker images for every PostgreSQL
# major this extension targets. Packages land in ./out.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=versions.env
source ./versions.env

version="$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -1)"
echo "==> accumulo_access_pg ${version}"

# The runtime Dockerfiles glob out/ for their major's package, so a stale
# package from an earlier version would be installed alongside the new one.
rm -f out/*.deb

for major in "${PG_STABLE}" "${PG_BETA}"; do
    echo "==> .deb for PostgreSQL ${major}"
    docker build -f Dockerfile.build \
        --build-arg "PG_MAJOR=${major}" \
        --build-arg "PGRX_VERSION=${PGRX_VERSION}" \
        --build-arg "DEBIAN_CODENAME=${DEBIAN_CODENAME}" \
        -o out .
done

build_postgres_image() {
    local major="$1" base="$2" tag="${2#postgres:}"
    echo "==> ${IMAGE_POSTGRES}:${tag}"
    docker build -f Dockerfile.postgres \
        --build-arg "BASE_IMAGE=${base}" \
        --build-arg "PG_MAJOR=${major}" \
        -t "${IMAGE_POSTGRES}:${tag}" .
}

build_postgres_image "${PG_STABLE}" "${PG_STABLE_IMAGE}"
build_postgres_image "${PG_BETA}" "${PG_BETA_IMAGE}"
# `latest` tracks the stable major, not the beta.
docker tag "${IMAGE_POSTGRES}:${PG_STABLE_IMAGE#postgres:}" "${IMAGE_POSTGRES}:latest"

echo "==> ${IMAGE_POSTGIS}:${POSTGIS_TAG}"
docker build -f Dockerfile.postgis \
    --build-arg "BASE_IMAGE=${POSTGIS_IMAGE}" \
    --build-arg "PG_MAJOR=${PG_STABLE}" \
    -t "${IMAGE_POSTGIS}:${POSTGIS_TAG}" .
docker tag "${IMAGE_POSTGIS}:${POSTGIS_TAG}" "${IMAGE_POSTGIS}:latest"

echo
echo "==> packages"
ls -1 out/
