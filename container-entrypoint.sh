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
# PostgreSQL data directory for version 17 (default in Debian Bookworm)
export POSTGRES_DIR=/var/lib/postgresql/17/main

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
    sudo mkdir -p /var/lib/postgresql/17/main
    sudo chown -R postgres:postgres /var/lib/postgresql
    # Initialize the database cluster as the 'postgres' user.
    sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D $POSTGRES_DIR
fi

echo "Starting PostgreSQL server..."
# Start the PostgreSQL server in the background as the 'postgres' user.
if ! sudo -u postgres pg_ctlcluster 17 main start; then
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

# --- 6. INITIALIZE AIRFLOW DATABASE AND CREATE ADMIN USER ---
echo "Initializing Airflow metadata database..."
# https://airflow.apache.org/docs/apache-airflow/stable/howto/set-up-database.html#initialize-the-database
airflow db migrate
airflow config get-value database sql_alchemy_conn

# echo "Creating Airflow admin user..."
# # Create the user, or ignore the error if the user already exists.
# airflow users create \
#     --username "${AIRFLOW_USER}" \
#     --firstname Airflow \
#     --lastname Admin \
#     --role Admin \
#     --email "${AIRFLOW_EMAIL}" \
#     -p "${AIRFLOW_PASSWORD}" || echo "User '${AIRFLOW_USER}' already exists."

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
