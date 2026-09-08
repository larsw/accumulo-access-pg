# Accumulo Access Expressions for PostgreSQL

## Introduction

This project provides a PostgreSQL extension that allows to parse, evaluate and filter rows (Row-Level Security) with Accumulo access expressions to be used in PostgreSQL queries.  The extension is implemented as a Rust extension to PostgreSQL.

The development wouldn't have been possible without the excellent [pgrx project](https://github.com/pgcentralfoundation/pgrx).

## Supported PostgreSQL versions

Built and integration-tested against:

| PostgreSQL | Cargo feature | Status                                          |
|------------|---------------|-------------------------------------------------|
| 18.6       | `pg18`        | default                                         |
| 19beta3    | `pg19`        | beta — tracks the newest beta PGDG publishes    |
| 13 – 17    | `pg13`…`pg17` | supported by pgrx, not covered by CI            |

Only one `pgNN` feature may be enabled at a time, and `pg18` is the default:

```bash
cargo build --release                                  # pg18
cargo build --release --no-default-features -F pg19    # pg19beta3
```

Toolchain: pgrx `0.19.2`, Rust edition 2024 (rustc 1.96 or newer).

## Installation

### Docker images

```bash
docker run -e POSTGRES_PASSWORD=secret larsw/postgres-accumulo-access:18-trixie
docker run -e POSTGRES_PASSWORD=secret larsw/postgres-accumulo-access:19beta3-trixie
docker run -e POSTGRES_PASSWORD=secret larsw/postgis-accumulo-access:18-3.6
```

The images create the extension in `$POSTGRES_DB` and in a `template_accumulo_access`
(or `template_postgis`) template database on first start.

PostGIS is offered for PostgreSQL 18 only: the `postgis/postgis` images still ship
19beta1, which is older than the beta this extension is built against.

### Debian packages

```bash
./build.sh                                   # writes out/*.deb and builds the images
sudo dpkg -i out/accumulo_access_trixie_pg18_*_amd64.deb
```

### From source

```bash
cargo install cargo-pgrx --version 0.19.2 --locked
cargo pgrx init --pg18=download              # or --pg18=$(which pg_config)
cargo pgrx run pg18
```

```sql
CREATE EXTENSION accumulo_access_pg;
```

## Usage

| Function                                            | Returns   | Purpose                                                     |
|-----------------------------------------------------|-----------|-------------------------------------------------------------|
| `sec_authz_check(expression text, tokens text)`     | `boolean` | Evaluate an expression against a comma-separated token list |
| `sec_expr_as_json(expression text)`                 | `json`    | Parse an expression into its JSON syntax tree               |
| `sec_expr_as_json_string(expression text)`          | `text`    | Same, as text                                               |
| `sec_authz_cache_stats()`                           | composite | `hits` / `misses` / `size` of the evaluation cache          |
| `sec_authz_clear_cache()`                           | `boolean` | Empty the evaluation cache                                  |

`sec_authz_check` returns `false` for a `NULL` or empty expression or token list, and
raises an error if the expression doesn't parse.

### Example with Row Level Security

```sql
create role users;
create user johnny;
grant users to johnny;

create table secret_stuff(id serial primary key, data text not null, authz_expr text not null);
alter table secret_stuff enable row level security;
insert into secret_stuff(data, authz_expr) values('pretty secret', 'label1');
insert into secret_stuff(data, authz_expr) values('moar secret', 'label1|label2');
insert into secret_stuff(data, authz_expr) values('wat', 'label2');
insert into secret_stuff(data, authz_expr) values('win', 'label2&(label3|label4)');

grant select on secret_stuff to users;

-- The `true` makes current_setting() return NULL instead of raising when the
-- session hasn't set any authorizations; sec_authz_check() then denies the row.
create policy evaluate_policies on secret_stuff using ( sec_authz_check(authz_expr, current_setting('session.authorizations', true)));

-- ...
set session authorization johnny;
select current_user,session_user;
-- current_user | session_user 
----------------+--------------
-- johnny       | johnny

set session.authorizations = 'label1';

select * from secret_stuff;
-- id |     data      |  authz_expr   
------+---------------+---------------
--  1 | pretty secret | label1
--  2 | moar secret   | label1|label2
-- (2 rows)

set session.authorizations = 'label2,label3';
select * from secret_stuff;
-- id |    data     |         authz_expr         
------+-------------+----------------------------
--  2 | moar secret | label1|label2
--  3 | wat         | label2
--  4 | win         | label2&(label3|label4)
-- (3 rows)
```

## Development

Everything runs in Docker, so no local PostgreSQL or pgrx install is required.
The targeted versions live in [`versions.env`](versions.env).

```bash
./test.sh          # both stages below
./test.sh pgrx     # in-backend #[pg_test] suite, against PG 18 and the 19 beta
./test.sh e2e      # build the .debs, install them into real server images,
                   # then run tests/integration.sql against each
./build.sh         # packages and images only
```

`./test.sh pgrx` builds [`Dockerfile.test`](Dockerfile.test), which installs both
PostgreSQL majors from PGDG (the 19 beta comes from the `-testing` suite, which is
ahead of the source tarball pgrx would download) and registers both with pgrx.

## TODO

* Make the caching feature configurable (strategy, size)
* Implement some benchmarks.
* Support for signed authorizations (JWT? Just raw signatures?)

## License

This project is licensed under both the Apache 2.0 license and the MIT license.  See the `LICENSE_APACHE` and `LICENSE_MIT` files for details.

## Contributions

Contributions are welcome.  Please open an issue or a pull request.
