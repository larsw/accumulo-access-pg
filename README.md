# Accumulo Access Expressions for PostgreSQL

## Introduction

This project provides a PostgreSQL extension that allows to parse, evaluate and filter rows (Row-Level Security) with Accumulo access expressions to be used in PostgreSQL queries.  The extension is implemented as a Rust extension to PostgreSQL.

The development wouldn't have been possible without the excellent [pgrx project](https://github.com/pgcentralfoundation/pgrx).

## Installation

_TODO_

```bash
cargo install cargo-pgrx
cargo pgrx init --pg15=download
cargo build --release
cargo pgrx run pg15
#cargo pgrx package
```

```sql
CREATE EXTENSION accumulo_access_pg;
```

## Usage

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
insert into secret_stuff(data, authz_expr) values('win', 'label2 & (label3 | label4)');

grant select on secret_stuff to users;

create policy evaluate_policies on secret_stuff using ( sec_authz_check(authz_expr, current_setting('session.authorizations')));

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
--  4 | win         | label2 & (label3 | label4)
-- (3 rows)
```

## TODO

* Make the caching feature configurable (strategy, size)
* Implement some benchmarks.
* Support for signed authorizations (JWT? Just raw signatures?)

## License

This project is licensed under both the Apache 2.0 license and the MIT license.  See the `LICENSE_APACHE` and `LICENSE_MIT` files for details.

## Contributions

Contributions are welcome.  Please open an issue or a pull request.
