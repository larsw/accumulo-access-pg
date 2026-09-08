#!/usr/bin/env bash
#
# Builds the .deb packages, and the runtime Docker images the end-to-end tests
# install them into, for every targeted PostgreSQL major or just the ones named.
# Packages land in ./out.
#
#   ./build.sh          # every major in versions.env
#   ./build.sh 18 19    # just these
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=versions.env
source ./versions.env

read -r -a all_majors <<< "$PG_MAJORS"
if [ "$#" -gt 0 ]; then
    majors=("$@")
    for major in "${majors[@]}"; do
        # shellcheck disable=SC2076
        if [[ ! " ${all_majors[*]} " =~ " ${major} " ]]; then
            echo "unknown major '$major'; versions.env lists: $PG_MAJORS" >&2
            exit 2
        fi
    done
else
    majors=("${all_majors[@]}")
fi

version="$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -1)"
echo "==> accumulo_access_pg ${version} for PostgreSQL ${majors[*]}"

for major in "${majors[@]}"; do
    echo "==> .deb for PostgreSQL ${major}"
    # The runtime Dockerfiles glob out/ for their major's package, so a package
    # left over from an earlier version would be installed alongside the new one.
    rm -f "out/accumulo_access_"*"_pg${major}_"*"_amd64.deb"
    docker build -f Dockerfile.build \
        --build-arg "PG_MAJOR=${major}" \
        --build-arg "PGRX_VERSION=${PGRX_VERSION}" \
        --build-arg "DEBIAN_CODENAME=${DEBIAN_CODENAME}" \
        -o out .
done

for major in "${majors[@]}"; do
    base_var="PG_IMAGE_${major}"
    base="${!base_var}"
    tag="${base#postgres:}"
    echo "==> ${IMAGE_POSTGRES}:${tag}"
    docker build -f Dockerfile.postgres \
        --build-arg "BASE_IMAGE=${base}" \
        --build-arg "PG_MAJOR=${major}" \
        -t "${IMAGE_POSTGRES}:${tag}" .
    # `latest` follows the default major, never a beta.
    if [ "$major" = "$PG_DEFAULT" ]; then
        docker tag "${IMAGE_POSTGRES}:${tag}" "${IMAGE_POSTGRES}:latest"
    fi

    postgis_var="POSTGIS_IMAGE_${major}"
    postgis="${!postgis_var:-}"
    if [ -n "$postgis" ]; then
        postgis_tag="${postgis#postgis/postgis:}"
        echo "==> ${IMAGE_POSTGIS}:${postgis_tag}"
        docker build -f Dockerfile.postgis \
            --build-arg "BASE_IMAGE=${postgis}" \
            --build-arg "PG_MAJOR=${major}" \
            -t "${IMAGE_POSTGIS}:${postgis_tag}" .
        if [ "$major" = "$PG_DEFAULT" ]; then
            docker tag "${IMAGE_POSTGIS}:${postgis_tag}" "${IMAGE_POSTGIS}:latest"
        fi
    fi
done

echo
echo "==> packages"
ls -1 out/
