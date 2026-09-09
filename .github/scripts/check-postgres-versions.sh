#!/usr/bin/env bash
#
# Checks whether the beta PostgreSQL versions pinned in versions.env are still
# the newest ones PGDG publishes.
#
# Stable majors need no checking: both the `postgresql-NN` packages and the
# `postgres:NN-trixie` image tags float to the newest minor on their own. Betas
# are pinned to an exact version because there is no floating tag for them, so
# they go stale silently -- and once PGDG drops the old beta from its -testing
# suite, the package build fails with an apt error rather than anything that
# explains itself.
#
# Prints a human-readable report, and writes one tab-separated line per finding
# to the file named by $1 (default: findings.tsv):
#
#   <major>  <kind>  <pinned>  <available>  <image-tag>  <image-available>
#
# Exits 0 whether or not anything was found; an empty findings file means the
# pins are current.
set -euo pipefail

cd "$(dirname "$0")/../.."
# shellcheck source=../../versions.env
source ./versions.env

findings="${1:-findings.tsv}"
: > "$findings"

pgdg_url="https://apt.postgresql.org/pub/repos/apt/dists"

# Newest version of a package in one suite/component, or empty if absent.
pgdg_version() {
    local suite="$1" component="$2" package="$3"
    curl -fsSL "${pgdg_url}/${suite}/${component}/binary-amd64/Packages.gz" 2>/dev/null \
        | gunzip 2>/dev/null \
        | awk -v pkg="$package" '
            $1 == "Package:" { match_pkg = ($2 == pkg) }
            match_pkg && $1 == "Version:" { print $2; exit }
          ' || true
}

# 19~beta3-1.pgdg13+1 -> 19beta3, matching how the Docker tags spell it.
upstream_version() {
    local version="${1%%-*}"
    echo "${version//\~/}"
}

# Whether library/postgres publishes a tag.
docker_tag_exists() {
    local tag="$1" status
    status="$(curl -sS -o /dev/null -w '%{http_code}' \
        "https://hub.docker.com/v2/repositories/library/postgres/tags/${tag}" || echo 000)"
    [ "$status" = "200" ]
}

report() { printf '%s\n' "$*"; }

if [ -z "${PG_BETA_MAJORS:-}" ]; then
    report "versions.env pins no beta majors; nothing to check."
    exit 0
fi

for major in $PG_BETA_MAJORS; do
    image_var="PG_IMAGE_${major}"
    pinned_image="${!image_var:-}"
    if [ -z "$pinned_image" ]; then
        report "PostgreSQL ${major}: listed in PG_BETA_MAJORS but has no PG_IMAGE_${major}; skipping."
        continue
    fi

    pinned_tag="${pinned_image#postgres:}"                 # 19beta3-trixie
    pinned="${pinned_tag%-"${DEBIAN_CODENAME}"}"           # 19beta3

    testing="$(pgdg_version "${DEBIAN_CODENAME}-pgdg-testing" "$major" "postgresql-${major}")"
    stable="$(pgdg_version "${DEBIAN_CODENAME}-pgdg" main "postgresql-${major}")"

    report "PostgreSQL ${major}"
    report "  pinned:        ${pinned}  (${pinned_image})"
    report "  pgdg-testing:  ${testing:-<absent>}"
    report "  pgdg stable:   ${stable:-<absent>}"

    # The major reaching general availability is the important transition: the
    # beta leaves the -testing suite, and the pin has to become the floating
    # stable tag with the major dropped from PG_BETA_MAJORS.
    if [ -n "$stable" ]; then
        available="$(upstream_version "$stable")"
        image_tag="${major}-${DEBIAN_CODENAME}"
        if docker_tag_exists "$image_tag"; then image_ok=yes; else image_ok=no; fi
        report "  => released: ${available} is in the stable suite"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$major" released "$pinned" "$available" "$image_tag" "$image_ok" >> "$findings"
        continue
    fi

    if [ -z "$testing" ]; then
        report "  => gone: no postgresql-${major} in either suite, the package build will fail"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$major" gone "$pinned" "" "" no >> "$findings"
        continue
    fi

    available="$(upstream_version "$testing")"
    if [ "$available" = "$pinned" ]; then
        report "  => current"
        continue
    fi

    image_tag="${available}-${DEBIAN_CODENAME}"
    if docker_tag_exists "$image_tag"; then image_ok=yes; else image_ok=no; fi
    report "  => newer beta: ${available} (postgres:${image_tag} published: ${image_ok})"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$major" newer "$pinned" "$available" "$image_tag" "$image_ok" >> "$findings"
done

if [ -s "$findings" ]; then
    report ""
    report "$(wc -l < "$findings") finding(s) written to ${findings}"
else
    report ""
    report "All beta pins are current."
fi
