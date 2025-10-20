#!/bin/sh

set -e

usage() {
  echo "Usage:"
  echo "$0 <OPERATION: create|update|list>"
  exit 1
}

OPERATION="${1}"
case "${OPERATION}"
in
  create) ;;
  update) ;;
  list) ;;
  *) echo "Error: OPERATION undefined"; usage;;
esac


test -n "${DBNAME}" || { echo "DBNAME is empty - check credentials in Vault"; exit 2; };
test -n "${DBSCHEMA}" || { echo "DBSCHEMA is empty - will use default 'public' schema"; DBSCHEMA="public"; };
test -n "${USERNAME}" || { echo "USERNAME is empty - check credentials in Vault"; exit 2; };
test -n "${PASSWORD}" || { echo "PASSWORD is empty - check credentials in Vault"; exit 2; };
test -n "${SU_NAME}" || { echo "SU_NAME is empty - check credentials in Vault"; exit 2; };
test -n "${SU_PASSWORD}" || { echo "SU_PASSWORD is empty - check credentials in Vault"; exit 2; };


if [ "${OPERATION}" = "list" ]; then
    echo "==== ROLES:"
    PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -c "SELECT rolname FROM pg_roles;"
    echo "==== DATABASES:"
    PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -c "SELECT datname FROM pg_database WHERE datistemplate = false;"
    echo "==== SCHEMAS:"
    PGPASSWORD="${PASSWORD}" psql -U "${USERNAME}" -d "${DBNAME}" -c "SELECT schema_name FROM information_schema.schemata;"
    echo "==== PRIVILEGES:"
    PGPASSWORD="${PASSWORD}" psql -U "${USERNAME}" -d "${DBNAME}" -c "SELECT grantee, privilege_type, table_catalog, table_schema, table_name FROM information_schema.role_table_grants;"
    exit 0
fi

if [ "${OPERATION}" = "create" ]; then
    PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -c "CREATE ROLE \"${USERNAME}\" CREATEDB LOGIN PASSWORD '${PASSWORD}';" && \
        PGPASSWORD="${PASSWORD}" psql -U "${USERNAME}" -c "CREATE DATABASE \"${DBNAME}\";" && \
        PGPASSWORD="${PASSWORD}" psql -U "${USERNAME}" -d "${DBNAME}" -c "CREATE SCHEMA \"${DBSCHEMA}\";" && \
        PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -d "${DBNAME}" -c "GRANT USAGE ON SCHEMA \"${DBSCHEMA}\" TO \"${USERNAME}\";" && \
        PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -d "${DBNAME}" -c "GRANT CREATE ON SCHEMA \"${DBSCHEMA}\" TO \"${USERNAME}\";"
    # return early with the last seen exit code - otherwise the next if [...] would return 0
    return $?
fi

if [ "${OPERATION}" = "update" ]; then
    PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -c "ALTER ROLE \"${USERNAME}\" CREATEDB LOGIN PASSWORD '${PASSWORD}';" && \
        PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -c "ALTER DATABASE \"${DBNAME}\" OWNER TO \"${USERNAME}\";" && \
        PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -d "${DBNAME}" -c "GRANT USAGE ON SCHEMA \"${DBSCHEMA}\" TO \"${USERNAME}\";" && \
        PGPASSWORD="${SU_PASSWORD}" psql -U "${SU_NAME}" -d "${DBNAME}" -c "GRANT CREATE ON SCHEMA \"${DBSCHEMA}\" TO \"${USERNAME}\";"
    return $?
fi
