#!/bin/bash -e

# --- 1. DEFINE DEFAULT ENVIRONMENT VARIABLES ---
# These can be overridden by passing `-e VAR=VALUE` to `docker run`.
export AIRFLOW_HOME=${AIRFLOW_HOME:-/opt/airflow}
export AIRFLOW__CORE__EXECUTOR=${AIRFLOW__CORE__EXECUTOR:-CeleryExecutor}
export AIRFLOW__CORE__LOAD_EXAMPLES=${AIRFLOW__CORE__LOAD_EXAMPLES:-true}
# Airflow UI credentials
export AIRFLOW_USER=${AIRFLOW_USER:-airflow}
export AIRFLOW_PASSWORD=${AIRFLOW_PASSWORD:-airflow}
export AIRFLOW_EMAIL=${AIRFLOW_EMAIL:-airflow@example.com}
# PostgreSQL credentials and database name
export POSTGRES_USER=${POSTGRES_USER:-airflow}
export POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-airflow}
export POSTGRES_DB=${POSTGRES_DB:-airflow}
# PostgreSQL version in the image
export POSTGRES_VERSION=18
# PostgreSQL data directory
export POSTGRES_DIR=/var/lib/postgresql/${POSTGRES_VERSION}/main

# --- 2. CONFIGURE AIRFLOW CONNECTIONS ---
# Set the environment variables that Airflow will use to connect to the database and broker.
# SQLAlchemy connection string for the metadata database.
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}"
# Celery broker URL. Using database 1 for the broker.
export AIRFLOW__CELERY__BROKER_URL="redis://localhost:6379/1"
# Celery result backend. Storing results in the PostgreSQL database.
export AIRFLOW__CELERY__RESULT_BACKEND="db+postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}"

echo '-- Airflow Environment Variables --'
printenv | grep AIRFLOW
echo '------'

# --- 3. INITIALIZE AND START POSTGRESQL ---
# Check if the PostgreSQL data directory has been initialized.
if [ ! -d "$POSTGRES_DIR" ]; then
    echo "PostgreSQL data directory not found. Initializing a new cluster..."
    # Create and set permissions for the data directory.
    # We must use 'sudo' because the 'airflow' user does not own these directories.
    sudo mkdir -p "/var/lib/postgresql/${POSTGRES_VERSION}/main"
    sudo chown -R postgres:postgres /var/lib/postgresql
    # Initialize the database cluster as the 'postgres' user.
    sudo -u postgres "/usr/lib/postgresql/${POSTGRES_VERSION}/bin/initdb" -D $POSTGRES_DIR
fi

echo "Starting PostgreSQL server..."
# Start the PostgreSQL server in the background as the 'postgres' user.
if ! sudo -u postgres pg_ctlcluster ${POSTGRES_VERSION} main start; then
    # sudo cat /var/log/postgresql/logfile
    echo 'FAIL, dropping to shell...'
    exec /bin/bash
fi

# Wait for PostgreSQL to become available before proceeding.
echo "Waiting for PostgreSQL to be ready..."
until sudo -u postgres psql -c "select 1" > /dev/null 2>&1; do
  echo -n "."
  sleep 1
done
echo "PostgreSQL is ready."
pg_lsclusters -h

# --- 4. CREATE AIRFLOW DATABASE AND USER IN POSTGRESQL ---
# This block creates the Airflow user and database if they don't already exist.
# It uses a `DO` block and a `\gexec` trick to perform conditional creation.
sudo -u postgres psql -v ON_ERROR_STOP=1 --dbname postgres <<-EOSQL
    DO \$\$
    BEGIN
       IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = '${POSTGRES_USER}') THEN
          CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';
       END IF;
    END
    \$\$;
    SELECT 'CREATE DATABASE ${POSTGRES_DB}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_DB}')\gexec
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};
    GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};
    ALTER DATABASE ${POSTGRES_DB} OWNER TO ${POSTGRES_USER};
EOSQL
echo "PostgreSQL user and database are configured."

# --- 5. START REDIS ---
echo "Starting Redis server..."
# Start Redis in daemon mode.
sudo redis-server /etc/redis/redis.conf --daemonize yes
# Wait for Redis to become available.
until redis-cli ping > /dev/null 2>&1; do
    echo "Waiting for Redis..."
    sleep 1
done
echo "Redis is ready."

# --- 6. INITIALIZE AIRFLOW DATABASE AND CONFIGURE AUTHENTICATION ---
echo "Initializing Airflow metadata database..."
# https://airflow.apache.org/docs/apache-airflow/stable/howto/set-up-database.html#initialize-the-database
airflow db migrate
airflow config get-value database sql_alchemy_conn

echo "Configuring Airflow authentication (SimpleAuthManager)..."
# In Airflow 3, SimpleAuthManager is the default for simple user management.
export AIRFLOW__CORE__AUTH_MANAGER="airflow.api_fastapi.auth.managers.simple.simple_auth_manager.SimpleAuthManager"
export AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_USERS="${AIRFLOW_USER}:admin"
export AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_PASSWORDS_FILE="${AIRFLOW_HOME}/simple_auth_manager_passwords.json"

# Create the passwords file with the specified password if it doesn't exist.
if [ ! -f "${AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_PASSWORDS_FILE}" ]; then
    echo "{\"${AIRFLOW_USER}\": \"${AIRFLOW_PASSWORD}\"}" > "${AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_PASSWORDS_FILE}"
    echo "User '${AIRFLOW_USER}' configured with password from AIRFLOW_PASSWORD."
fi

# Proxy and Base URL configuration
# Explicitly disable ProxyFix. This is enabled by default in Airflow 3 and might be
# incorrectly prepending a prefix due to misconfigured X-Forwarded-* headers in complex proxy chains.
# We will rely on explicit subpath patching instead.
export AIRFLOW__WEBSERVER__ENABLE_PROXY_FIX=False
# AIRFLOW__WEBSERVER__BASE_URL is used by the UI to set the <base href> tag.
export AIRFLOW__WEBSERVER__BASE_URL=$(echo "${AIRFLOW__WEBSERVER__BASE_URL:-http://localhost:8080}" | sed 's|/*$|/|')
# AIRFLOW__API__BASE_URL: for Airflow 3 behind a stripping proxy, we MUST set this to /
# so that the backend routing doesn't expect the subpath prefix in incoming requests.
export AIRFLOW__API__BASE_URL="/"

echo "Applying subpath patch to Airflow source..."
AIRFLOW_SITE_PACKAGES=$(python3 -c "import airflow; import os; print(os.path.dirname(airflow.__file__))" 2>/dev/null || echo "/home/airflow/.local/lib/python3.13/site-packages/airflow")
UI_BASE_PATH=$(python3 -c "from urllib.parse import urlsplit; print(urlsplit('${AIRFLOW__WEBSERVER__BASE_URL}').path)" 2>/dev/null || echo "/")

# Patch AUTH_MANAGER_FASTAPI_APP_PREFIX specifically to ensure redirects use the subpath.
# We DO NOT patch API_ROOT_PATH directly as it affects the FastAPI root_path/router.
sed -i "s|^AUTH_MANAGER_FASTAPI_APP_PREFIX = .*|AUTH_MANAGER_FASTAPI_APP_PREFIX = \"${UI_BASE_PATH}auth\"|g" \
    "${AIRFLOW_SITE_PACKAGES}/api_fastapi/app.py"

# Patch Core UI template to use the full subpath for <base href>
sed -i "s|\"backend_server_base_url\": request.base_url.path|\"backend_server_base_url\": \"${UI_BASE_PATH}\"|g" \
    "${AIRFLOW_SITE_PACKAGES}/api_fastapi/core_api/app.py"

# Patch SimpleAuthManager Login UI template
sed -i "s|\"backend_server_base_url\": request.base_url.path|\"backend_server_base_url\": \"${UI_BASE_PATH}\"|g" \
    "${AIRFLOW_SITE_PACKAGES}/api_fastapi/auth/managers/simple/simple_auth_manager.py"

echo "Starting Airflow scheduler..."
airflow scheduler &

echo "Starting Airflow worker..."
airflow celery worker &

echo "Starting Airflow triggerer..."
airflow triggerer &

echo "Starting Airflow DAG processor..."
airflow dag-processor > /tmp/dag-processor &

echo "Starting Airflow API server..."
exec airflow api-server --proxy-headers
