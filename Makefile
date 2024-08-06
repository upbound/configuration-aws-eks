# Project Setup
PROJECT_NAME := configuration-aws-eks
PROJECT_REPO := github.com/upbound/$(PROJECT_NAME)

# NOTE(hasheddan): the platform is insignificant here as Configuration package
# images are not architecture-specific. We constrain to one platform to avoid
# needlessly pushing a multi-arch image.
PLATFORMS ?= linux_amd64
-include build/makelib/common.mk

# ====================================================================================
# Setup Kubernetes tools

UP_VERSION = v0.32.1
UP_CHANNEL = stable
UPTEST_VERSION = v0.11.1
CROSSPLANE_CLI_VERSION=v1.16.0

-include build/makelib/k8s_tools.mk
# ====================================================================================
# Setup XPKG
XPKG_DIR = $(shell pwd)
XPKG_IGNORE = .github/workflows/*.yaml,.github/workflows/*.yml,examples/*.yaml,.work/uptest-datasource.yaml,apis/composition-kcl.yaml
XPKG_REG_ORGS ?= xpkg.upbound.io/upbound
# NOTE(hasheddan): skip promoting on xpkg.upbound.io as channel tags are
# inferred.
XPKG_REG_ORGS_NO_PROMOTE ?= xpkg.upbound.io/upbound
XPKGS = $(PROJECT_NAME)
-include build/makelib/xpkg.mk

CROSSPLANE_VERSION = 1.16.0-up.1
CROSSPLANE_CHART_REPO = https://charts.upbound.io/stable
CROSSPLANE_CHART_NAME = universal-crossplane
CROSSPLANE_NAMESPACE = upbound-system
CROSSPLANE_ARGS = "--enable-usages"
KIND_CLUSTER_NAME = uptest-$(PROJECT_NAME)
-include build/makelib/local.xpkg.mk
-include build/makelib/controlplane.mk

# ====================================================================================
# Targets

# run `make help` to see the targets and options

# We want submodules to be set up the first time `make` is run.
# We manage the build/ folder and its Makefiles as a submodule.
# The first time `make` is run, the includes of build/*.mk files will
# all fail, and this target will be run. The next time, the default as defined
# by the includes will be run instead.
fallthrough: submodules
	@echo Initial setup complete. Running make again . . .
	@make

submodules: ## Update the submodules, such as the common build scripts.
	@git submodule sync
	@git submodule update --init --recursive

# We must ensure up is installed in tool cache prior to build as including the k8s_tools machinery prior to the xpkg
# machinery sets UP to point to tool cache.
build.init: $(UP) kcl-generate

# ====================================================================================
# End to End Testing

# This target requires the following environment variables to be set:
# - UPTEST_CLOUD_CREDENTIALS, cloud credentials for the provider being tested, e.g. export UPTEST_CLOUD_CREDENTIALS=$(cat ~/.aws/credentials)
# - To ensure the proper functioning of the end-to-end test resource pre-deletion hook, it is crucial to arrange your resources appropriately.
#   You can check the basic implementation here: https://github.com/upbound/uptest/blob/main/internal/templates/01-delete.yaml.tmpl.
# - UPTEST_DATASOURCE_PATH (optional), see https://github.com/upbound/uptest#injecting-dynamic-values-and-datasource
SKIP_DELETE ?=
uptest: $(UPTEST) $(KUBECTL) $(KUTTL)
	@$(INFO) running automated tests
	@KUBECTL=$(KUBECTL) KUTTL=$(KUTTL) CROSSPLANE_NAMESPACE=$(CROSSPLANE_NAMESPACE) $(UPTEST) e2e examples/network-xr.yaml,examples/network-xr-kcl.yaml,examples/eks-xr.yaml,examples/eks-xr-kcl.yaml --data-source="${UPTEST_DATASOURCE_PATH}" --setup-script=test/setup.sh --default-timeout=2400 $(SKIP_DELETE) || $(FAIL)
	@$(OK) running automated tests

# This target requires the following environment variables to be set:
# - UPTEST_CLOUD_CREDENTIALS, cloud credentials for the provider being tested, e.g. export UPTEST_CLOUD_CREDENTIALS=$(cat ~/.aws/credentials)
# Use `make e2e SKIP_DELETE=--skip-delete` to skip deletion of resources created during the test.
e2e: build controlplane.up local.xpkg.deploy.configuration.$(PROJECT_NAME) uptest  ## Run uptest together with all dependencies. Use `make e2e SKIP_DELETE=--skip-delete` to skip deletion of resources.

kcl-generate: $(KCL) ## Generate KCL-based Composition
	$(KCL) generate-composition.k

render-kcl: kcl-generate $(CROSSPLANE_CLI) ## Crossplane render kcl generated composition
	$(CROSSPLANE_CLI) beta render examples/eks-xr.yaml apis/composition-kcl-generated.yaml examples/functions.yaml -r

render: $(CROSSPLANE_CLI) ## Crossplane render
	$(CROSSPLANE_CLI) beta render examples/eks-xr.yaml apis/composition.yaml examples/functions.yaml -r

yamllint: ## Static yamllint check
	@$(INFO) running yamllint
	@yamllint ./apis || $(FAIL)
	@$(OK) running yamllint

help.local:
	@grep -E '^[a-zA-Z_-]+.*:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: uptest e2e render yamllint help.local
