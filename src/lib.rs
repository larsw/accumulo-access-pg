// Copyright 2024 Lars Wilhelmsen <sral-backwards@sral.org>. All rights reserved.
// Use of this source code is governed by the MIT or Apache-2.0 license that can be found in the LICENSE-MIT or LICENSE-APACHE files.

use accumulo_access::{
    expression_to_json_string,
    expression_to_json,
};

use accumulo_access::caching::{
    authz_cache_stats,
    check_authorization_csv,
    clear_authz_cache,
};
use pgrx::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value::Null;

::pgrx::pg_module_magic!(name, version);

#[pg_extern]
fn sec_authz_check(expression: Option<&str>, tokens: Option<&str>) -> bool {
    if expression.is_none() || tokens.is_none() {
        return false;
    }
    let expression = expression.unwrap();
    let tokens = tokens.unwrap();

    if expression.is_empty() {
        return false;
    }
    if tokens.is_empty() {
        return false;
    }
    match check_authorization_csv(expression.to_string(), tokens.to_string()) {
        Ok(result) => result,
        Err(e) => {
            let msg = format!("Error parsing expression: {}", e);
            error!("{}", msg)
        }
    }
}

#[derive(Serialize, Deserialize, PostgresType, Debug)]
pub struct SecAuthzCacheStats {
    pub hits: u64,
    pub misses: u64,
    pub size: usize,
}

#[pg_extern]
fn sec_authz_cache_stats() -> SecAuthzCacheStats {
    match authz_cache_stats() {
        Ok(stats) => SecAuthzCacheStats { hits: stats.hits, misses: stats.misses, size: stats.size},
        Err(e) => {
            let msg = format!("Error getting cache stats: {}", e);
            error!("{}", msg)
        }
    }
}

#[pg_extern]
fn sec_authz_clear_cache() -> bool {
    match clear_authz_cache() {
        Ok(_) => true,
        Err(e) => {
            let msg = format!("Error clearing cache: {}", e);
            error!("{}", msg)
        }
    }
}

#[pg_extern]
fn sec_expr_as_json_string(expression: Option<&str>) -> String {
    if expression.is_none() {
        return "".into();
    }
    let expression = expression.unwrap();
    if expression.is_empty() {
        return "".into();
    }

    match expression_to_json_string(expression) {
        Ok(json) => json.as_str().into(),
        Err(e) => {
            let msg = format!("Error parsing expression: {}", e);
            error!("{}", msg)
        }
    }
}

#[pg_extern]
fn sec_expr_as_json(expression: Option<&str>) -> pgrx::Json {
    if expression.is_none() {
        return pgrx::Json(Null);
    }
    let expression = expression.unwrap();
    if expression.is_empty() {
        return pgrx::Json(Null);
    }

    match expression_to_json(expression) {
        Ok(json) => pgrx::Json(json),
        Err(e) => {
            let msg = format!("Error parsing expression: {}", e);
            error!("{}", msg)
        }
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    /// Direct call, no SQL round-trip: the parser/evaluator itself.
    #[pg_test]
    fn test_accumulo_check_authorization() {
        let expression = "label1&label5&(label2|\"label 🕺\")";
        let tokens = "label1,label5,label 🕺";
        assert!(crate::sec_authz_check(Some(expression), Some(tokens)));
    }

    #[pg_test]
    fn test_authz_check_denies_when_token_missing() {
        assert!(!crate::sec_authz_check(Some("label1&label2"), Some("label1")));
    }

    #[pg_test]
    fn test_authz_check_null_and_empty_arguments_deny() {
        assert!(!crate::sec_authz_check(None, Some("label1")));
        assert!(!crate::sec_authz_check(Some("label1"), None));
        assert!(!crate::sec_authz_check(Some(""), Some("label1")));
        assert!(!crate::sec_authz_check(Some("label1"), Some("")));
    }

    /// Everything below goes through SPI, so it exercises the generated SQL
    /// declarations and the fmgr calling convention, not just the Rust fns.
    #[pg_test]
    fn test_authz_check_via_spi() {
        let granted = Spi::get_one::<bool>(
            "SELECT sec_authz_check('label1|label2', 'label2')",
        )
        .expect("SPI failed");
        assert_eq!(Some(true), granted);

        let denied = Spi::get_one::<bool>(
            "SELECT sec_authz_check('label2&(label3|label4)', 'label2')",
        )
        .expect("SPI failed");
        assert_eq!(Some(false), denied);
    }

    #[pg_test]
    fn test_authz_check_with_sql_nulls_via_spi() {
        let result =
            Spi::get_one::<bool>("SELECT sec_authz_check(NULL, 'label1')").expect("SPI failed");
        assert_eq!(Some(false), result);
    }

    #[pg_test]
    fn test_expr_as_json_string_via_spi() {
        let json = Spi::get_one::<String>("SELECT sec_expr_as_json_string('label1&label2')")
            .expect("SPI failed")
            .expect("expected a json string");
        // Serialisation order is an implementation detail of accumulo-access,
        // so assert on the structure rather than on an exact string.
        let parsed: serde_json::Value =
            serde_json::from_str(&json).expect("sec_expr_as_json_string returned invalid JSON");
        assert!(parsed.is_object(), "expected a JSON object, got {parsed}");
        assert!(json.contains("label1"), "{json}");
        assert!(json.contains("label2"), "{json}");
    }

    #[pg_test]
    fn test_expr_as_json_string_empty_input() {
        let json = Spi::get_one::<String>("SELECT sec_expr_as_json_string('')")
            .expect("SPI failed");
        assert_eq!(Some(String::new()), json);
    }

    #[pg_test]
    fn test_expr_as_json_returns_json_type_via_spi() {
        // ->> forces Postgres to treat the result as a real `json` value.
        let type_name = Spi::get_one::<String>(
            "SELECT pg_typeof(sec_expr_as_json('label1&label2'))::text",
        )
        .expect("SPI failed");
        assert_eq!(Some("json".to_string()), type_name);

        let is_object = Spi::get_one::<bool>(
            "SELECT json_typeof(sec_expr_as_json('label1&label2')) = 'object'",
        )
        .expect("SPI failed");
        assert_eq!(Some(true), is_object);
    }

    #[pg_test]
    fn test_expr_as_json_null_input_yields_json_null() {
        let is_null = Spi::get_one::<bool>(
            "SELECT json_typeof(sec_expr_as_json(NULL)) = 'null'",
        )
        .expect("SPI failed");
        assert_eq!(Some(true), is_null);
    }

    #[pg_test]
    fn test_cache_stats_and_clear_via_spi() {
        assert_eq!(
            Some(true),
            Spi::get_one::<bool>("SELECT sec_authz_clear_cache()").expect("SPI failed")
        );

        // A miss followed by a hit for the same expression/token pair.
        for _ in 0..2 {
            Spi::get_one::<bool>("SELECT sec_authz_check('label1|label2', 'label1')")
                .expect("SPI failed");
        }

        // `sec_authz_cache_stats()` returns the extension's own composite type,
        // whose output function is the serde JSON representation.
        let stats = read_cache_stats();

        assert!(
            stats["hits"].as_u64().expect("hits") >= 1,
            "expected at least one cache hit: {stats}"
        );
        assert!(
            stats["misses"].as_u64().expect("misses") >= 1,
            "expected at least one cache miss: {stats}"
        );
        assert!(
            stats["size"].as_u64().expect("size") >= 1,
            "expected a non-empty cache: {stats}"
        );

        assert_eq!(
            Some(true),
            Spi::get_one::<bool>("SELECT sec_authz_clear_cache()").expect("SPI failed")
        );
        let cleared = read_cache_stats();
        assert_eq!(Some(0), cleared["size"].as_u64());
    }

    fn read_cache_stats() -> serde_json::Value {
        let raw = Spi::get_one::<String>("SELECT sec_authz_cache_stats()::text")
            .expect("SPI failed")
            .expect("expected cache stats");
        serde_json::from_str(&raw)
            .unwrap_or_else(|e| panic!("cache stats are not valid JSON ({e}): {raw}"))
    }

    /// The row-level-security scenario from the README, end to end.
    #[pg_test]
    fn test_row_level_security_policy() {
        Spi::run(
            "CREATE TABLE secret_stuff(id serial primary key, data text not null, authz_expr text not null);
             INSERT INTO secret_stuff(data, authz_expr) VALUES
                ('pretty secret', 'label1'),
                ('moar secret',   'label1|label2'),
                ('wat',           'label2'),
                ('win',           'label2&(label3|label4)');",
        )
        .expect("failed to create fixture table");

        let visible = |authorizations: &str| -> i64 {
            Spi::get_one::<i64>(&format!(
                "SELECT count(*) FROM secret_stuff
                 WHERE sec_authz_check(authz_expr, '{authorizations}')"
            ))
            .expect("SPI failed")
            .expect("count is never NULL")
        };

        assert_eq!(2, visible("label1"));
        assert_eq!(3, visible("label2,label3"));
        assert_eq!(0, visible("label9"));
    }

    /// A malformed expression has to come back as a Postgres ERROR, not a panic
    /// across the FFI boundary and not a silent reinterpretation.
    #[pg_test(error = "Error parsing expression: Mixing operators")]
    fn test_mixed_operators_raise() {
        Spi::get_one::<bool>("SELECT sec_authz_check('label1&label2|label3', 'label1,label2')")
            .expect("SPI failed");
    }

    #[pg_test(error = "Error parsing expression: Unexpected end of expression")]
    fn test_trailing_operator_raises() {
        Spi::get_one::<bool>("SELECT sec_authz_check('label1&', 'label1')").expect("SPI failed");
    }

    #[pg_test(error = "Error parsing expression: Unexpected token: &")]
    fn test_repeated_operator_raises() {
        Spi::get_one::<bool>("SELECT sec_authz_check('label1&&label2', 'label1,label2')")
            .expect("SPI failed");
    }

    #[pg_test(error = "Error parsing expression: Empty scope")]
    fn test_empty_scope_raises() {
        Spi::get_one::<bool>("SELECT sec_authz_check('()', 'label1')").expect("SPI failed");
    }

    /// Guards the version the extension actually got loaded into.
    #[pg_test]
    fn test_running_on_expected_postgres_major() {
        let major = Spi::get_one::<i32>("SELECT current_setting('server_version_num')::int / 10000")
            .expect("SPI failed")
            .expect("server_version_num is always set");

        #[cfg(feature = "pg13")]
        assert_eq!(13, major);
        #[cfg(feature = "pg14")]
        assert_eq!(14, major);
        #[cfg(feature = "pg15")]
        assert_eq!(15, major);
        #[cfg(feature = "pg16")]
        assert_eq!(16, major);
        #[cfg(feature = "pg17")]
        assert_eq!(17, major);
        #[cfg(feature = "pg18")]
        assert_eq!(18, major);
        #[cfg(feature = "pg19")]
        assert_eq!(19, major);
    }
}

/// This module is required by `cargo pgrx test` invocations.
/// It must be visible at the root of your extension crate.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // perform one-off initialization when the pg_test framework starts
    }

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // return any postgresql.conf settings that are required for your tests
        vec![]
    }
}
