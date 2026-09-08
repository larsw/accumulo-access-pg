-- End-to-end check against a running server that has accumulo_access_pg
-- installed from its .deb. Any failed ASSERT aborts psql with a non-zero exit.
\set ON_ERROR_STOP on

SELECT current_setting('server_version') AS server_version,
       (SELECT extversion FROM pg_extension WHERE extname = 'accumulo_access_pg')
         AS extension_version;

-- The image's initdb hook is what creates the extension; don't paper over it.
DO $$
BEGIN
    ASSERT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'accumulo_access_pg'),
        'accumulo_access_pg was not created by the image init script';
END
$$;

-- sec_authz_check
DO $$
BEGIN
    ASSERT sec_authz_check('label1&label5&(label2|"label 🕺")',
                           'label1,label5,label 🕺'),
        'quoted/multibyte label should be authorized';
    ASSERT sec_authz_check('label1|label2', 'label2');
    ASSERT NOT sec_authz_check('label1&label2', 'label1'),
        'missing conjunct must deny';
    ASSERT NOT sec_authz_check('label2&(label3|label4)', 'label2');
    ASSERT sec_authz_check('label2&(label3|label4)', 'label2,label4');
    ASSERT NOT sec_authz_check(NULL, 'label1'), 'NULL expression must deny';
    ASSERT NOT sec_authz_check('label1', NULL), 'NULL tokens must deny';
    ASSERT NOT sec_authz_check('', 'label1'), 'empty expression must deny';
    ASSERT NOT sec_authz_check('label1', ''), 'empty tokens must deny';
END
$$;

-- sec_expr_as_json / sec_expr_as_json_string
DO $$
DECLARE
    as_text text;
BEGIN
    ASSERT pg_typeof(sec_expr_as_json('label1&label2')) = 'json'::regtype;
    ASSERT json_typeof(sec_expr_as_json('label1&label2')) = 'object';
    ASSERT json_typeof(sec_expr_as_json(NULL)) = 'null',
        'NULL input should yield JSON null';

    as_text := sec_expr_as_json_string('label1&label2');
    ASSERT as_text <> '' AND as_text LIKE '%label1%' AND as_text LIKE '%label2%',
        format('unexpected json string: %s', as_text);
    ASSERT json_typeof(as_text::json) = 'object';
    ASSERT sec_expr_as_json_string('') = '', 'empty input should yield empty string';
END
$$;

-- A malformed expression has to surface as a Postgres ERROR rather than unwind
-- into the backend, quietly return false, or get reinterpreted as something
-- valid. Every form below was silently accepted before accumulo-access 0.2.0.
DO $$
DECLARE
    bad text;
    message text;
BEGIN
    FOREACH bad IN ARRAY ARRAY[
        'label1&',                -- trailing operator
        'label1|',
        '&label1',                -- leading operator
        '|label1',
        'label1&&label2',         -- repeated operator
        'label1||label2',
        '(label1',                -- unclosed scope
        'label1&(label2',
        'label1)',                -- unbalanced close
        '()',                     -- empty scope
        '(())',
        'label1&label2|label3'    -- mixed operators in one scope
    ] LOOP
        message := NULL;
        BEGIN
            PERFORM sec_authz_check(bad, 'label1,label2,label3');
        EXCEPTION
            WHEN others THEN
                message := SQLERRM;
        END;
        ASSERT message LIKE 'Error parsing expression:%',
            format('%L should have been rejected, got: %s', bad,
                   coalesce(message, 'no error at all'));
    END LOOP;
END
$$;

-- ...and the backend has to still be usable afterwards.
DO $$
BEGIN
    ASSERT sec_authz_check('label1|label2', 'label1');
END
$$;

-- Cache stats and invalidation
DO $$
DECLARE
    stats json;
BEGIN
    ASSERT sec_authz_clear_cache();
    PERFORM sec_authz_check('label1|label2', 'label1');
    PERFORM sec_authz_check('label1|label2', 'label1');

    stats := sec_authz_cache_stats()::text::json;
    ASSERT (stats->>'hits')::bigint >= 1, format('expected a cache hit: %s', stats);
    ASSERT (stats->>'misses')::bigint >= 1, format('expected a cache miss: %s', stats);
    ASSERT (stats->>'size')::bigint >= 1, format('expected a warm cache: %s', stats);

    ASSERT sec_authz_clear_cache();
    stats := sec_authz_cache_stats()::text::json;
    ASSERT (stats->>'size')::bigint = 0, format('cache should be empty: %s', stats);
END
$$;

-- The row-level-security scenario from the README, with a real unprivileged role.
CREATE ROLE aa_users;
CREATE ROLE johnny LOGIN;
GRANT aa_users TO johnny;

CREATE TABLE secret_stuff(
    id serial primary key,
    data text not null,
    authz_expr text not null
);
ALTER TABLE secret_stuff ENABLE ROW LEVEL SECURITY;
INSERT INTO secret_stuff(data, authz_expr) VALUES
    ('pretty secret', 'label1'),
    ('moar secret',   'label1|label2'),
    ('wat',           'label2'),
    ('win',           'label2&(label3|label4)');
GRANT SELECT ON secret_stuff TO aa_users;
CREATE POLICY evaluate_policies ON secret_stuff
    USING (sec_authz_check(authz_expr, current_setting('session.authorizations', true)));

SET SESSION AUTHORIZATION johnny;

DO $$
BEGIN
    ASSERT current_user = 'johnny', 'expected to be running as johnny';
    ASSERT (SELECT count(*) FROM secret_stuff) = 0,
        'no rows should be visible without session.authorizations set';
END
$$;

SET session.authorizations = 'label1';
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM secret_stuff) = 2,
        format('label1 should see 2 rows, saw %s', (SELECT count(*) FROM secret_stuff));
END
$$;

SET session.authorizations = 'label2,label3';
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM secret_stuff) = 3,
        format('label2,label3 should see 3 rows, saw %s', (SELECT count(*) FROM secret_stuff));
END
$$;

SET session.authorizations = 'label9';
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM secret_stuff) = 0,
        'an unrelated authorization should see nothing';
END
$$;

RESET SESSION AUTHORIZATION;
DROP TABLE secret_stuff;
DROP ROLE johnny;
DROP ROLE aa_users;

\echo 'accumulo_access_pg integration tests passed'
