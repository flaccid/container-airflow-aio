DOCKER_REGISTRY = index.docker.io
IMAGE_NAME = airflow-aio
IMAGE_VERSION = latest
IMAGE_ORG = flaccid
IMAGE_TAG = $(DOCKER_REGISTRY)/$(IMAGE_ORG)/$(IMAGE_NAME):$(IMAGE_VERSION)
KUBE_NAMESPACE = default

WORKING_DIR := $(shell pwd)

.DEFAULT_GOAL := help

.PHONY: build

docker-release:: docker-build docker-push ## Builds and pushes the docker image to the registry

docker-push:: ## Pushes the docker image to the registry
		@docker push $(IMAGE_TAG)

docker-build:: ## builds the docker image locally
		@docker build  \
			--pull \
			-t $(IMAGE_TAG) \
				$(WORKING_DIR)

docker-build-clean:: ## cleanly builds the docker image locally
		@docker build  \
			--no-cache \
			--pull \
			-t $(IMAGE_TAG) \
				$(WORKING_DIR)

docker-pull:: ## pulls the docker image locally
		@docker pull $(IMAGE_TAG)

docker-run:: ## Runs the docker image
		docker run \
			--name airflow-aio \
			-it \
			--rm \
			-p 8080:8080 \
			$(OPTS) \
				$(IMAGE_TAG) $(ARGS)

docker-exec-shell:: ## Executes a shell in running container
		@docker exec \
			-it \
				airflow-aio /bin/bash

docker-run-shell:: ## Runs the docker image with bash as entrypoint
		@docker run \
			-it \
			--entrypoint /bin/sh \
				$(IMAGE_TAG)

docker-rm:: ## Removes the running docker container
		@docker rm -f airflow-aio

docker-test:: ## tests the runtime of the docker image in a basic sense
		@docker run $(IMAGE_TAG) airflow-aio --version

helm-install:: ## installs using helm from chart in repo
		@helm install \
			-f helm-values.yaml \
			--namespace $(KUBE_NAMESPACE) \
				airflow-aio ./charts/airflow-aio

helm-upgrade:: ## upgrades deployed helm release
		@helm upgrade \
			-f helm-values.yaml \
			--namespace $(KUBE_NAMESPACE) \
				airflow-aio ./charts/airflow-aio

helm-uninstall:: ## deletes and purges deployed helm release
		@helm uninstall \
			--namespace $(KUBE_NAMESPACE) \
				airflow-aio

helm-reinstall:: helm-uninstall helm-install ## Uninstalls the helm release, then installs it again

helm-render:: ## prints out the rendered chart
		@helm install \
			-f helm-values.yaml \
			--namespace $(KUBE_NAMESPACE) \
			--dry-run \
			--debug \
				airflow-aio ./charts/airflow-aio

helm-validate:: ## runs a lint on the helm chart
		@helm lint \
			-f helm-values.yaml \
			--namespace $(KUBE_NAMESPACE) \
				charts/airflow-aio

helm-package:: ## packages the helm chart into an archive
		@helm package charts/airflow-aio

helm-index:: ## creates/updates the helm repo index file
		@helm repo index --url https://flaccid.github.io/container-airflow-aio/ .

helm-flush:: ## removes local helm packages and index file
		@rm -f ./airflow-aio-*.tgz
		@rm -f index.yaml

# A help target including self-documenting targets (see the awk statement)
define HELP_TEXT
Usage: make [TARGET]... [MAKEVAR1=SOMETHING]...

Available targets:
endef
export HELP_TEXT
help: ## This help target
	@cat .banner
	@echo
	@echo "$$HELP_TEXT"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / \
		{printf "\033[36m%-30s\033[0m  %s\n", $$1, $$2}' $(MAKEFILE_LIST)
