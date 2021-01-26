include variables.mk

.PHONY: all
all: status checkmake clean build verify install container-runtime-build container-runtime-images ## Build the image
	@echo "+ $@"

.PHONY: check-env
check-env: ## Checks the environment variables
	@echo "+ $@"
	@echo "NAME: $(NAME)"
ifeq ($(NAME),)
	$(error You must provide application name)
endif
	@echo "VERSION: $(VERSION)"
ifeq ($(VERSION),)
	$(error You must provide application version)
endif
	@echo "PKG: $(PKG)"
ifeq ($(PKG),)
	$(error You must provide application package)
endif
	@echo "VERSION_TAG: $(VERSION_TAG)"
	@echo "LATEST_TAG: $(LATEST_TAG)"
	@echo "BUILD_TAG: $(BUILD_TAG)"
ifneq ($(GITUNTRACKEDCHANGES),)
	@echo "Changes: \n$(GITUNTRACKEDCHANGES)"
endif

.PHONY: go-init
HAS_GIT := $(shell which git)
HAS_GO := $(shell which go)
go-init: ## Ensure build time dependencies
	@echo "+ $@"
ifndef HAS_GIT
	$(warning You must install git)
endif
ifndef HAS_GO
	$(warning You must install go)
endif

.PHONY: go-dependencies
go-dependencies: ## Ensure build dependencies
	@echo "+ $@"
	@echo "Ensure Golang runtime dependencies"
	go mod vendor -v

.PHONY: build
build: deepcopy-gen $(NAME) ## Builds a dynamic executable or package
	@echo "+ $@"

.PHONY: $(NAME)
$(NAME): $(wildcard *.go) $(wildcard */*.go) VERSION.txt
	@echo "+ $@"
	CGO_ENABLED=0 go build -tags "$(BUILDTAGS)" ${GO_LDFLAGS} -o bin/manager $(BUILD_PATH)

.PHONY: static
static: ## Builds a static executable
	@echo "+ $@"
	CGO_ENABLED=0 go build \
				-tags "$(BUILDTAGS) static_build" \
				${GO_LDFLAGS_STATIC} -o $(NAME) $(BUILD_PATH)

.PHONY: fmt
fmt: ## Verifies all files have been `gofmt`ed
	@echo "+ $@"
	@go fmt $(PACKAGES)

.PHONY: lint
HAS_GOLINT := $(shell which golangci-lint)
lint: ## Verifies `golint` passes
	@echo "+ $@"
ifndef HAS_GOLINT
	go get github.com/golangci/golangci-lint/cmd/golangci-lint@v1.26.0
endif
	@golangci-lint run

.PHONY: goimports
HAS_GOIMPORTS := $(shell which goimports)
goimports: ## Verifies `goimports` passes
	@echo "+ $@"
ifndef HAS_GOIMPORTS
	go get -u golang.org/x/tools/cmd/goimports
endif
	@goimports -l -e $(shell find . -type f -name '*.go' -not -path "./vendor/*")

.PHONY: test
test: ## Runs the go tests
	@echo "+ $@"
	@RUNNING_TESTS=1 go test -tags "$(BUILDTAGS) cgo" $(PACKAGES_FOR_UNIT_TESTS)

.PHONY: e2e
e2e: deepcopy-gen ## Runs e2e tests, you can use EXTRA_ARGS
	@echo "+ $@"
	RUNNING_TESTS=1 go test -parallel=1 "./test/e2e/" -tags "$(BUILDTAGS) cgo" -v -timeout 60m -run "$(E2E_TEST_SELECTOR)" \
		$(TEST_ARGS)

.PHONY: vet
vet: ## Verifies `go vet` passes
	@echo "+ $@"
	@go vet $(PACKAGES)

#FIXME download to tmp not locally
.PHONY: staticcheck
HAS_STATICCHECK := $(shell which staticcheck)
PLATFORM  = $(shell echo $(UNAME_S) | tr A-Z a-z)
staticcheck: ## Verifies `staticcheck` passes
	@echo "+ $@"
ifndef HAS_STATICCHECK
	wget -O staticcheck_$(PLATFORM)_amd64.tar.gz https://github.com/dominikh/go-tools/releases/download/2020.1.3/staticcheck_$(PLATFORM)_amd64.tar.gz
	tar zxvf staticcheck_$(PLATFORM)_amd64.tar.gz
	mkdir -p $(GOPATH)/bin
	mv staticcheck/staticcheck $(GOPATH)/bin
endif
	@staticcheck $(PACKAGES)

.PHONY: cover
cover: ## Runs go test with coverage
	@echo "" > coverage.txt
	@for d in $(PACKAGES); do \
		IMG_RUNNING_TESTS=1 go test -race -coverprofile=profile.out -covermode=atomic "$$d"; \
		if [ -f profile.out ]; then \
			cat profile.out >> coverage.txt; \
			rm profile.out; \
		fi; \
	done;

.PHONY: verify
verify: fmt lint test staticcheck vet ## Verify the code
	@echo "+ $@"

.PHONY: install
install: ## Installs the executable
	@echo "+ $@"
	go install -tags "$(BUILDTAGS)" ${GO_LDFLAGS} $(BUILD_PATH)

.PHONY: run
run: export WATCH_NAMESPACE = $(NAMESPACE)
run: export OPERATOR_NAME = $(NAME)
run: fmt vet manifests install-crds build ## Run the executable, you can use EXTRA_ARGS
	@echo "+ $@"
ifeq ($(KUBERNETES_PROVIDER),minikube)
	kubectl config use-context $(KUBECTL_CONTEXT)
endif
ifeq ($(KUBERNETES_PROVIDER),crc)
	oc project $(CRC_OC_PROJECT)
endif
	@echo "Watching '$(WATCH_NAMESPACE)' namespace"
	bin/manager $(OPERATOR_ARGS)

.PHONY: clean
clean: ## Cleanup any build binaries or packages
	@echo "+ $@"
	go clean
	rm $(NAME) || echo "Couldn't delete, not there."
	rm -r $(BUILDDIR) || echo "Couldn't delete, not there."

.PHONY: spring-clean
spring-clean: ## Cleanup git ignored files (interactive)
	git clean -Xdi

define buildpretty
mkdir -p $(BUILDDIR)/$(1)/$(2);
GOOS=$(1) GOARCH=$(2) CGO_ENABLED=0 go build \
		-o $(BUILDDIR)/$(1)/$(2)/$(NAME) \
		-a -tags "$(BUILDTAGS) static_build netgo" \
		-installsuffix netgo ${GO_LDFLAGS_STATIC} $(BUILD_PATH);
md5sum $(BUILDDIR)/$(1)/$(2)/$(NAME) > $(BUILDDIR)/$(1)/$(2)/$(NAME).md5;
sha256sum $(BUILDDIR)/$(1)/$(2)/$(NAME) > $(BUILDDIR)/$(1)/$(2)/$(NAME).sha256;
endef

.PHONY: cross
cross: $(wildcard *.go) $(wildcard */*.go) VERSION.txt ## Builds the cross-compiled binaries, creating a clean directory structure (eg. GOOS/GOARCH/binary)
	@echo "+ $@"
	$(foreach GOOSARCH,$(GOOSARCHES), $(call buildpretty,$(subst /,,$(dir $(GOOSARCH))),$(notdir $(GOOSARCH))))

define buildrelease
GOOS=$(1) GOARCH=$(2) CGO_ENABLED=0 go build \
	 -o $(BUILDDIR)/$(NAME)-$(1)-$(2) \
	 -a -tags "$(BUILDTAGS) static_build netgo" \
	 -installsuffix netgo ${GO_LDFLAGS_STATIC} $(BUILD_PATH);
md5sum $(BUILDDIR)/$(NAME)-$(1)-$(2) > $(BUILDDIR)/$(NAME)-$(1)-$(2).md5;
sha256sum $(BUILDDIR)/$(NAME)-$(1)-$(2) > $(BUILDDIR)/$(NAME)-$(1)-$(2).sha256;
endef

.PHONY: release
release: $(wildcard *.go) $(wildcard */*.go) VERSION.txt ## Builds the cross-compiled binaries, naming them in such a way for release (eg. binary-GOOS-GOARCH)
	@echo "+ $@"
	$(foreach GOOSARCH,$(GOOSARCHES), $(call buildrelease,$(subst /,,$(dir $(GOOSARCH))),$(notdir $(GOOSARCH))))

.PHONY: checkmake
HAS_CHECKMAKE := $(shell which checkmake)
checkmake: ## Check this Makefile
	@echo "+ $@"
ifndef HAS_CHECKMAKE
	go get -u github.com/mrtazz/checkmake
endif
	@checkmake Makefile

.PHONY: container-runtime-login
container-runtime-login: ## Log in into the Docker repository
	@echo "+ $@"

.PHONY: container-runtime-build
container-runtime-build: check-env ## Build the container
	@echo "+ $@"
	$(CONTAINER_RUNTIME_COMMAND) build \
	--build-arg GO_VERSION=$(GO_VERSION) \
	--build-arg OPERATOR_SDK_VERSION=$(OPERATOR_SDK_VERSION) \
	-t $(DOCKER_REGISTRY):$(GITCOMMIT) . \
	--file build/Dockerfile $(CONTAINER_RUNTIME_EXTRA_ARGS)

.PHONY: container-runtime-images
container-runtime-images: ## List all local containers
	@echo "+ $@"
	$(CONTAINER_RUNTIME_COMMAND) images $(CONTAINER_RUNTIME_EXTRA_ARGS)

.PHONY: container-runtime-push
container-runtime-push: ## Push the container
	@echo "+ $@"
	$(CONTAINER_RUNTIME_COMMAND) tag $(DOCKER_REGISTRY):$(GITCOMMIT) $(DOCKER_ORGANIZATION)/$(DOCKER_REGISTRY):$(BUILD_TAG) $(CONTAINER_RUNTIME_EXTRA_ARGS)
	$(CONTAINER_RUNTIME_COMMAND) push $(DOCKER_ORGANIZATION)/$(DOCKER_REGISTRY):$(BUILD_TAG) $(CONTAINER_RUNTIME_EXTRA_ARGS)

.PHONY: container-runtime-snapshot-push
container-runtime-snapshot-push:
	@echo "+ $@"
	$(CONTAINER_RUNTIME_COMMAND) tag $(DOCKER_REGISTRY):$(GITCOMMIT) $(DOCKER_ORGANIZATION)/$(DOCKER_REGISTRY):$(GITCOMMIT) $(CONTAINER_RUNTIME_EXTRA_ARGS)
	$(CONTAINER_RUNTIME_COMMAND) push $(DOCKER_ORGANIZATION)/$(DOCKER_REGISTRY):$(GITCOMMIT) $(CONTAINER_RUNTIME_EXTRA_ARGS)

.PHONY: container-runtime-release-version
container-runtime-release-version: ## Release image with version tag (in addition to build tag)
	@echo "+ $@"
	$(CONTAINER_RUNTIME_COMMAND) tag $(DOCKER_REGISTRY):$(GITCOMMIT) $(DOCKER_ORGANIZATION)/$(DOCKER_REGISTRY):$(VERSION_TAG) $(CONTAINER_RUNTIME_EXTRA_ARGS)
	$(CONTAINER_RUNTIME_COMMAND) push $(DOCKER_ORGANIZATION)/$(DOCKER_REGISTRY):$(VERSION_TAG) $(CONTAINER_RUNTIME_EXTRA_ARGS)

.PHONY: container-runtime-release-latest
container-runtime-release-latest: ## Release image with latest tags (in addition to build tag)
	@echo "+ $@"
	$(CONTAINER_RUNTIME_COMMAND) tag $(DOCKER_REGISTRY):$(GITCOMMIT) $(DOCKER_ORGANIZATION)/$(DOCKER_REGISTRY):$(LATEST_TAG) $(CONTAINER_RUNTIME_EXTRA_ARGS)
	$(CONTAINER_RUNTIME_COMMAND) push $(DOCKER_ORGANIZATION)/$(DOCKER_REGISTRY):$(LATEST_TAG) $(CONTAINER_RUNTIME_EXTRA_ARGS)

.PHONY: container-runtime-release
container-runtime-release: container-runtime-build container-runtime-release-version container-runtime-release-latest ## Release image with version and latest tags (in addition to build tag)
	@echo "+ $@"

# if this session isn't interactive, then we don't want to allocate a
# TTY, which would fail, but if it is interactive, we do want to attach
# so that the user can send e.g. ^C through.
INTERACTIVE := $(shell [ -t 0 ] && echo 1 || echo 0)
ifeq ($(INTERACTIVE), 1)
    DOCKER_FLAGS += -t
endif

.PHONY: container-runtime-run
container-runtime-run: ## Run the container in docker, you can use EXTRA_ARGS
	@echo "+ $@"
	$(CONTAINER_RUNTIME_COMMAND) run $(CONTAINER_RUNTIME_EXTRA_ARGS) --rm -i $(DOCKER_FLAGS) \
		--volume $(HOME)/.kube/config:/home/jenkins-operator/.kube/config \
		$(DOCKER_REGISTRY):$(GITCOMMIT) /usr/bin/jenkins-operator $(OPERATOR_ARGS)

.PHONY: minikube-run
minikube-run: export WATCH_NAMESPACE = $(NAMESPACE)
minikube-run: export OPERATOR_NAME = $(NAME)
minikube-run: minikube-start run ## Run the operator locally and use minikube as Kubernetes cluster, you can use OPERATOR_ARGS
	@echo "+ $@"

.PHONY: crc-run
crc-run: export WATCH_NAMESPACE = $(NAMESPACE)
crc-run: export OPERATOR_NAME = $(NAME)
crc-run: crc-start run ## Run the operator locally and use CodeReady Containers as Kubernetes cluster, you can use OPERATOR_ARGS
	@echo "+ $@"

.PHONY: deepcopy-gen
deepcopy-gen: generate ## Generate deepcopy golang code
	@echo "+ $@"

.PHONY: scheme-doc-gen
HAS_GEN_CRD_API_REFERENCE_DOCS := $(shell ls gen-crd-api-reference-docs 2> /dev/null)
scheme-doc-gen: ## Generate Jenkins CRD scheme doc
	@echo "+ $@"
ifndef HAS_GEN_CRD_API_REFERENCE_DOCS
	@wget https://github.com/ahmetb/$(GEN_CRD_API)/releases/download/v0.1.2/$(GEN_CRD_API)_linux_amd64.tar.gz
	@mkdir -p $(GEN_CRD_API)
	@tar -C $(GEN_CRD_API) -zxf $(GEN_CRD_API)_linux_amd64.tar.gz
	@rm $(GEN_CRD_API)_linux_amd64.tar.gz
endif
	$(GEN_CRD_API)/$(GEN_CRD_API) -config gen-crd-api-config.json -api-dir github.com/jenkinsci/kubernetes-operator/pkg/apis/jenkins/$(API_VERSION) -template-dir $(GEN_CRD_API)/template -out-file documentation/$(VERSION)/jenkins-$(API_VERSION)-scheme.md

.PHONY: check-minikube
check-minikube: ## Checks if KUBERNETES_PROVIDER is set to minikube
	@echo "+ $@"
	@echo "KUBERNETES_PROVIDER '$(KUBERNETES_PROVIDER)'"
ifneq ($(KUBERNETES_PROVIDER),minikube)
	$(error KUBERNETES_PROVIDER not set to 'minikube')
endif

.PHONY: check-crc
check-crc: ## Checks if KUBERNETES_PROVIDER is set to crc
	@echo "+ $@"
	@echo "KUBERNETES_PROVIDER '$(KUBERNETES_PROVIDER)'"
ifneq ($(KUBERNETES_PROVIDER),crc)
	$(error KUBERNETES_PROVIDER not set to 'crc')
endif

.PHONY: minikube-start
minikube-start: check-minikube ## Start minikube
	@echo "+ $@"
	@minikube status && exit 0 || \
	minikube start --kubernetes-version $(MINIKUBE_KUBERNETES_VERSION) --dns-domain=$(CLUSTER_DOMAIN) --extra-config=kubelet.cluster-domain=$(CLUSTER_DOMAIN) --vm-driver=$(MINIKUBE_DRIVER) --memory 4096 --cpus 3

.PHONY: crc-start
crc-start: check-crc ## Start CodeReady Containers Kubernetes cluster
	@echo "+ $@"
	crc start

.PHONY: bump-version
BUMP := patch
bump-version: ## Bump the version in the version file. Set BUMP to [ patch | major | minor ]
	@echo "+ $@"
	#@go get -u github.com/jessfraz/junk/sembump # update sembump tool FIXME
	$(eval NEW_VERSION=$(shell sembump --kind $(BUMP) $(VERSION)))
	@echo "Bumping VERSION.txt from $(VERSION) to $(NEW_VERSION)"
	echo $(NEW_VERSION) > VERSION.txt
	@echo "Updating version from $(VERSION) to $(NEW_VERSION) in README.md"
	sed -i s/$(VERSION)/$(NEW_VERSION)/g README.md
	sed -i s/$(VERSION)/$(NEW_VERSION)/g deploy/operator.yaml
	sed -i s/$(VERSION)/$(NEW_VERSION)/g deploy/$(ALL_IN_ONE_DEPLOY_FILE_PREFIX)-$(API_VERSION).yaml
	cp deploy/service_account.yaml deploy/$(ALL_IN_ONE_DEPLOY_FILE_PREFIX)-$(API_VERSION).yaml
	cat deploy/role.yaml >> deploy/$(ALL_IN_ONE_DEPLOY_FILE_PREFIX)-$(API_VERSION).yaml
	cat deploy/role_binding.yaml >> deploy/$(ALL_IN_ONE_DEPLOY_FILE_PREFIX)-$(API_VERSION).yaml
	cat deploy/operator.yaml >> deploy/$(ALL_IN_ONE_DEPLOY_FILE_PREFIX)-$(API_VERSION).yaml
	git add VERSION.txt README.md deploy/operator.yaml deploy/$(ALL_IN_ONE_DEPLOY_FILE_PREFIX)-$(API_VERSION).yaml
	git commit -vaem "Bump version to $(NEW_VERSION)"
	@echo "Run make tag to create and push the tag for new version $(NEW_VERSION)"

.PHONY: tag
tag: ## Create a new git tag to prepare to build a release
	@echo "+ $@"
	git tag -s -a $(VERSION) -m "$(VERSION)"
	git push origin $(VERSION)

.PHONY: help
help:
	@grep -Eh '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: status
status: ## Shows git status
	@echo "+ $@"
	@echo "Commit: $(GITCOMMIT), VERSION: $(VERSION)"
	@echo
ifneq ($(GITUNTRACKEDCHANGES),)
	@echo "Changed files:"
	@git status --porcelain --untracked-files=no
	@echo
endif
ifneq ($(GITIGNOREDBUTTRACKEDCHANGES),)
	@echo "Ignored but tracked files:"
	@git ls-files -i --exclude-standard
	@echo
endif
	@echo "Dependencies:"
	go mod vendor -v
	@echo

.PHONY: helm-package
helm-package:
	@echo "+ $@"
	mkdir -p /tmp/jenkins-operator-charts
	mv chart/jenkins-operator/*.tgz /tmp/jenkins-operator-charts
	cd chart && helm package jenkins-operator
	mv /tmp/jenkins-operator-charts/*.tgz chart/jenkins-operator/
	rm -rf /tmp/jenkins-operator-charts/

.PHONY: helm-deploy
helm-deploy: helm-package
	@echo "+ $@"
	helm repo index chart/ --url https://raw.githubusercontent.com/jenkinsci/kubernetes-operator/master/chart/jenkins-operator/
	cd chart/ && mv jenkins-operator-*.tgz jenkins-operator

.PHONY: generate-docs
generate-docs: ## Re-generate docs directory from the website directory
	@echo "+ $@"
	rm -rf docs || echo "Cannot remove docs dir, ignoring"
	hugo -s website -d ../docs

##################### FROM OPERATOR SDK ########################
# Install CRDs into a cluster
install-crds: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Download controller-gen locally if necessary
CONTROLLER_GEN = $(shell pwd)/bin/controller-gen
controller-gen:
	$(call go-get-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen@v0.4.1)

# Download kustomize locally if necessary
KUSTOMIZE = $(shell pwd)/bin/kustomize
kustomize:
	$(call go-get-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v3@v3.8.7)

# go-get-tool will 'go get' any package $2 and install it to $1.
PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
define go-get-tool
@[ -f $(1) ] || { \
set -e ;\
TMP_DIR=$$(mktemp -d) ;\
cd $$TMP_DIR ;\
go mod init tmp ;\
echo "Downloading $(2)" ;\
GOBIN=$(PROJECT_DIR)/bin go get $(2) ;\
rm -rf $$TMP_DIR ;\
}
endef

# Generate bundle manifests and metadata, then validate generated files.
.PHONY: bundle
bundle: manifests kustomize
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

# Build the bundle image.
.PHONY: bundle-build
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

# Download kubebuilder
kubebuilder:
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.7.0/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR);