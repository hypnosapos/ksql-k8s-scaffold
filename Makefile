.DEFAULT_GOAL := help

# Shell to use with Make
SHELL ?= /bin/bash
ROOT_PATH := $(PWD)/$({0%/*})

DOCKER_CONT_NAME  ?= gke-bastion

GCLOUD_IMAGE_TAG    ?= 206.0.0-alpine
GCP_CREDENTIALS     ?= $$HOME/gcp.json
GCP_ZONE            ?= zone
GCP_PROJECT_ID      ?= my_project

GKE_CLUSTER_VERSION ?= 1.10.6-gke.1
GKE_CLUSTER_NAME    ?= confluent-platform
GKE_NUM_NODES       ?= 3
GKE_MACHINE_TYPE    ?= n1-standard-8

GITHUB_TOKEN        ?= githubtoken
CP_TAG              ?= v5.0.0-1

UNAME := $(shell uname -s)
ifeq ($(UNAME),Linux)
OPEN := xdg-open
else
OPEN := open
endif

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: gke-bastion
gke-bastion: ## Run a gke-bastion container.
	@docker run -it -d --name $(DOCKER_CONT_NAME) \
	   -p 8001:8001 \
	   -v $(GCP_CREDENTIALS):/tmp/gcp.json \
	   google/cloud-sdk:$(GCLOUD_IMAGE_TAG) \
	   sh
	@docker exec $(DOCKER_CONT_NAME) \
	   sh -c "gcloud components install kubectl beta --quiet \
	          && gcloud auth activate-service-account --key-file=/tmp/gcp.json"

.PHONY: gke-create-cluster
gke-create-cluster: ## Create a kubernetes cluster on GKE.
	@docker exec $(DOCKER_CONT_NAME) \
	   sh -c "gcloud beta container --project $(GCP_PROJECT_ID) clusters create $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" \
	          --username "admin" --cluster-version "$(GKE_CLUSTER_VERSION)" --machine-type "$(GKE_MACHINE_TYPE)" \
	          --image-type "COS" --disk-type "pd-standard" --disk-size "100" \
	          --scopes "compute-rw","storage-rw","logging-write","monitoring","service-control","service-management","trace" \
	          --num-nodes $(GKE_NUM_NODES) --enable-cloud-logging --enable-cloud-monitoring --network "default" \
	          --subnetwork "default" --addons HorizontalPodAutoscaling,HttpLoadBalancing,KubernetesDashboard"
	@docker exec $(DOCKER_CONT_NAME) \
	   sh -c "gcloud container clusters get-credentials $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" --project $(GCP_PROJECT_ID) \
	          && kubectl config set-credentials gke_$(GCP_PROJECT_ID)_$(GCP_ZONE)_$(GKE_CLUSTER_NAME) --username=admin \
	          --password=$$(gcloud container clusters describe $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" | grep password | awk '{print $$2}')"

.PHONY: gke-ui-login-skip
gke-ui-login-skip: ## TRICK: Grant complete access to dashboard. Be careful, anyone could enter into your dashboard and execute admin ops.
	@docker cp $(ROOT_PATH)/skip_login.yml gke-bastion:/tmp/skip_login.yml
	@docker exec $(DOCKER_CONT_NAME) \
	  sh -c "kubectl create -f /tmp/skip_login.yml"

.PHONY: gke-proxy
gke-proxy: ## Run kubectl proxy on gke container.
	@docker exec -it -d gke-bastion \
	   sh -c "kubectl proxy --address='0.0.0.0'"

.PHONY: gke-tiller-helm
gke-tiller-helm: ## Install Helm on GKE cluster.
	@docker exec $(DOCKER_CONT_NAME) \
	  sh -c "apk --update add openssl \
	         && curl  -H 'Cache-Control: no-cache' -H 'Authorization: token $(GITHUB_TOKEN)' https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash \
	         && kubectl -n kube-system create sa tiller \
	         && kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller \
	         && helm init --wait --service-account tiller"

.PHONY: gke-ksql-install
gke-ksql-install: ## Installing ksql components
	@docker exec $(DOCKER_CONT_NAME) \
	  sh -c "git clone https://github.com/confluentinc/cp-helm-charts.git \
	         && helm repo update \
	         && helm install --name my-confluent-oss cp-helm-charts"

.PHONY: gke-ksql-uninstall
gke-ksql-uninstall: ## Uninstalling ksql components
	@docker exec $(DOCKER_CONT_NAME) \
	  sh -c "helm del --purge my-confluent-oss"

.PHONY: gke-delete-cluster
gke-delete-cluster: ## Delete a kubernetes cluster on GKE.
	@docker exec $(DOCKER_CONT_NAME) \
	   sh -c "gcloud config set project $(GCP_PROJECT_ID) \
	          && gcloud container --project $(GCP_PROJECT_ID) clusters delete $(GKE_CLUSTER_NAME) \
	          --zone $(GCP_ZONE) --quiet"

.PHONY: gke-ui
gke-ui: ## Launch kubernetes dashboard through the proxy.
	$(OPEN) http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/

.PHONY: ksql-gke-conf
ksql-gke-conf: ## GKE ksql configuration
	@gcloud container clusters get-credentials $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" --project $(GCP_PROJECT_ID)
	@kubectl config set-credentials gke_$(GCP_PROJECT_ID)_$(GCP_ZONE)_$(GKE_CLUSTER_NAME) --username=admin \
	--password=$$(gcloud container clusters describe $(GKE_CLUSTER_NAME) --zone "$(GCP_ZONE)" | grep password | awk '{print $$2}')
	@kubectl create -f ksql-cli.yaml
	@while [ $$(kubectl get pod ksql-cli -o=jsonpath='{.status.phase}') != "Running" ]; do sleep 1; done
	@kubectl exec -ti ksql-cli ksql http://$$(kubectl get svc -l app=cp-ksql-server -o=jsonpath='{.items[0].spec.clusterIP}'):8088

.PHONY: ksql-local-conf
ksql-local-conf: ## Local ksql configuration
	@echo "Execute: ksql http://$$(kubectl get svc -l app=cp-ksql-server -o=jsonpath='{.items[0].spec.clusterIP}'):8088"