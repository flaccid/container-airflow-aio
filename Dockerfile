ARG AIRFLOW_VERSION=3.1.7
FROM apache/airflow:${AIRFLOW_VERSION}-python3.12
LABEL maintainer="Chris Fordham <chris@fordham.id.au>"
LABEL warning="This is an all-in-one image designed for local development and testing ONLY. DO NOT use it in a production environment."
COPY container-entrypoint.sh /usr/local/bin/container-entrypoint.sh
ENV AIRFLOW__API__EXPOSE_CONFIG=True
ENV AIRFLOW_HOME=/opt/airflow
ENV AIRFLOW__CORE__EXECUTOR=CeleryExecutor
ENV AIRFLOW__CORE__LOAD_EXAMPLES=true
ENV AIRFLOW_USER=airflow
ENV AIRFLOW_PASSWORD=airflow
ENV AIRFLOW__SCHEDULER__DAG_DIR_LIST_INTERVAL=30
ENV POSTGRES_USER=airflow
ENV POSTGRES_PASSWORD=airflow
ENV POSTGRES_DB=airflow
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    postgresql \
    procps \
    redis-server \
    sudo \
    libpq-dev \
    gcc && \
    mkdir -p /var/log/postgresql && \
    chown postgres:postgres /var/log/postgresql && \
    apt-get autoremove -yqq --purge && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
RUN echo "airflow ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/airflow-nopasswd
USER airflow
EXPOSE 8080
EXPOSE 5555
EXPOSE 6379
EXPOSE 5432
WORKDIR $AIRFLOW_HOME
ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]
