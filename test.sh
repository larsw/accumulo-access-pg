#!/usr/bin/env bash
#
# Integration tests for accumulo_access_pg against every PostgreSQL major it
# targets. Everything runs in Docker, so no local Postgres or pgrx is needed.
#
#   ./test.sh              # both stages, every major in versions.env
#   ./test.sh pgrx         # in-backend #[pg_test] suite, every major
#   ./test.sh pgrx 18      # ...just pg18
#   ./test.sh e2e 18 19    # install the .deb into real server images and run SQL
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=versions.env
source ./versions.env

stage="all"
if [ "$#" -gt 0 ] && [[ ! "$1" =~ ^[0-9]+$ ]]; then
    stage="$1"
    shift
fi

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

run_pgrx_tests() {
    echo "==> building ${IMAGE_TOOLCHAIN} (PostgreSQL ${PG_MAJORS}, pgrx ${PGRX_VERSION})"
    docker build -f Dockerfile.test \
        --build-arg "PGRX_VERSION=${PGRX_VERSION}" \
        --build-arg "PG_MAJORS=${PG_MAJORS}" \
        --build-arg "PG_BETA_MAJORS=${PG_BETA_MAJORS}" \
        -t "${IMAGE_TOOLCHAIN}" .

    # Named volumes keep the cargo registry and target dir out of the work tree.
    docker volume create aapg-target >/dev/null
    docker volume create aapg-registry >/dev/null

    for major in "${majors[@]}"; do
        echo "==> cargo pgrx test pg${major}"
        docker run --rm \
            -v "$PWD:/work" \
            -v aapg-target:/home/pgrx/target \
            -v aapg-registry:/home/pgrx/.cargo/registry \
            "${IMAGE_TOOLCHAIN}" \
            bash -lc "cargo pgrx test pg${major}"
    done
}

# Boots an image, waits for the server, and runs tests/integration.sql against it.
run_sql_suite() {
    local image="$1" label="$2"
    local container="aapg-e2e-$$-${label}"
    local rc=0 ready=""

    echo "==> ${label}: ${image}"
    docker run -d --name "$container" \
        -e POSTGRES_PASSWORD=accumulo \
        -e POSTGRES_DB=accumulo \
        "$image" >/dev/null

    # During initdb the entrypoint's temporary server listens on the unix socket
    # only, so TCP is what tells us the real server is up.
    for _ in $(seq 1 120); do
        if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -d accumulo -q; then
            ready=yes
            break
        fi
        sleep 1
    done

    if [ -z "$ready" ]; then
        echo "!! ${label}: server never became ready" >&2
        docker logs "$container" >&2
        rc=1
    else
        docker exec -i "$container" \
            psql -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d accumulo -f - \
            < tests/integration.sql || rc=$?
    fi

    docker rm -f "$container" >/dev/null 2>&1 || true
    return "$rc"
}

run_e2e_tests() {
    ./build.sh "${majors[@]}"

    for major in "${majors[@]}"; do
        base_var="PG_IMAGE_${major}"
        base="${!base_var}"
        run_sql_suite "${IMAGE_POSTGRES}:${base#postgres:}" "pg${major}"

        postgis_var="POSTGIS_IMAGE_${major}"
        postgis="${!postgis_var:-}"
        if [ -n "$postgis" ]; then
            run_sql_suite "${IMAGE_POSTGIS}:${postgis#postgis/postgis:}" "postgis-pg${major}"
        fi
    done
}

case "$stage" in
    pgrx) run_pgrx_tests ;;
    e2e)  run_e2e_tests ;;
    all)  run_pgrx_tests; run_e2e_tests ;;
    *)    echo "usage: $0 [pgrx|e2e|all] [major...]" >&2; exit 2 ;;
esac

echo
echo "all integration tests passed"
