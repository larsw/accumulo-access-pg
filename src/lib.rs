// Copyright 2024 Lars Wilhelmsen <sral-backwards@sral.org>. All rights reserved.
// Use of this source code is governed by the MIT or Apache-2.0 license that can be found in the LICENSE-MIT or LICENSE-APACHE files.

use accumulo_access::caching::{authz_cache_stats, check_authorization_csv, clear_authz_cache};
use pgrx::prelude::*;
use serde::{Deserialize, Serialize};

pg_module_magic!();

#[pg_extern]
fn sec_authz_check(expression: String, tokens: String) -> bool {
    match check_authorization_csv(expression, tokens) {
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

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn test_accumulo_check_authorization() {
        let expression = String::from("label1 & label5 & (label2 | \"label 🕺\")");
        let tokens = String::from("label1,label5,label 🕺");
        assert_eq!(true, crate::sec_authz_check(expression, tokens));
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
