# container-airflow-aio

Apache Airflow All-In-One container solution.

## Usage

```
make help
```

### Examples

Basic:

```
docker run \
    --name airflow-aio \
    -it \
    --rm \
    -p 8080:8080 \
    flaccid/airflow-aio
```

Serving on a base URL:

```
docker run \
    --name airflow-aio \
    -it \
    --rm \
    -p 8080:8080 \
    -e AIRFLOW__WEBSERVER__BASE_URL=https://kubeflow.my.suf/notebook/dev/airflow-dev-0/proxy/8080/ \
        flaccid/airflow-aio
```
