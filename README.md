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
    -e AIRFLOW__WEBSERVER__BASE_URL=https://airflow.example.com/ \
        flaccid/airflow-aio
```

## Usage with deployKF / Kubeflow

When running Airflow inside a Kubeflow notebook (e.g. a code-server notebook),
the Airflow UI is accessed through a multi-layer proxy chain:

```
Browser → Istio VirtualService → Notebook Service → code-server /proxy/8080/ → Airflow
```

This creates two problems:

1. **Broken static assets** - The proxy chain strips the URL path prefix before
   forwarding to Airflow, but the browser needs to request assets using the full
   proxy path. Airflow's `<base href>` must reflect the external proxy path.

2. **Broken auth redirects** - Airflow's login redirect responses use absolute
   paths (e.g. `Location: /auth/login`) which resolve to the domain root in the
   browser, bypassing the notebook proxy entirely.

### Solution

Set `AIRFLOW_UI_BASE_PATH` to the external URL path and enable
`SIMPLE_AUTH_MANAGER_ALL_ADMINS` to bypass the redirect-based login flow
(Kubeflow already handles authentication at the gateway level):

```
docker run \
    --name airflow-aio \
    -d \
    -p 8080:8080 \
    -e AIRFLOW_UI_BASE_PATH="${NB_PREFIX}/proxy/8080/" \
    -e AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_ALL_ADMINS=True \
        flaccid/airflow-aio
```

`NB_PREFIX` is automatically set inside Kubeflow notebook containers
(e.g. `/notebook/<namespace>/<notebook-name>`).

After the container starts, the Airflow UI is accessible at:

```
https://<deploykf-host>/notebook/<namespace>/<notebook-name>/proxy/8080/
```

### How it works

When `AIRFLOW_UI_BASE_PATH` is set, the entrypoint:

1. Patches the Airflow UI `index.html` templates to use the specified path as
   the `<base href>`, ensuring relative asset URLs resolve through the proxy.
2. When `SIMPLE_AUTH_MANAGER_ALL_ADMINS=True`, injects an inline script that
   auto-authenticates by requesting a JWT token from `./auth/token` and storing
   it as a cookie. This avoids the redirect-based login flow which breaks behind
   path-stripping proxies.

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AIRFLOW_UI_BASE_PATH` | External URL path prefix for the UI (e.g. `/notebook/ns/name/proxy/8080/`) | _(unset)_ |
| `AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_ALL_ADMINS` | Treat all users as admin without login | `false` |
| `AIRFLOW__WEBSERVER__BASE_URL` | Full external URL (used for legacy config fallback) | `http://localhost:8080` |
| `AIRFLOW__API__BASE_URL` | FastAPI root path for routing (keep as `/` behind stripping proxies) | `/` |
