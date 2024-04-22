#!/bin/bash

set -e

# Perform all actions as $POSTGRES_USER
export PGUSER="$POSTGRES_USER"

# Create the 'template_accumulo_access' template db
"${psql[@]}" <<- 'EOSQL'
CREATE DATABASE template_accumulo_access IS_TEMPLATE true;
EOSQL

# Load accumulo_access_pg into both template_database and $POSTGRES_DB
for DB in template_accumulo_access "$POSTGRES_DB"; do
	echo "Loading accumulo_access_pg extension into $DB"
	"${psql[@]}" --dbname="$DB" <<-'EOSQL'
        CREATE EXTENSION IF NOT EXISTS accumulo_access_pg;
EOSQL
done
