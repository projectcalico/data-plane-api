# Shortcut targets
default: proto
all: proto

###############################################################################
# Both native and cross architecture builds are supported.
# The target architecture is select by setting the ARCH variable.
# When ARCH is undefined it is set to the detected host architecture.
# When ARCH differs from the host architecture a crossbuild will be performed.
ARCHES=$(patsubst Dockerfile.%,%,$(wildcard Dockerfile.*))

# BUILDARCH is the host architecture
# ARCH is the target architecture
# we need to keep track of them separately
BUILDARCH ?= $(shell uname -m)

# canonicalized names for host architecture
ifeq ($(BUILDARCH),aarch64)
	BUILDARCH=arm64
endif
ifeq ($(BUILDARCH),x86_64)
	BUILDARCH=amd64
endif

# unless otherwise set, I am building for my own architecture, i.e. not cross-compiling
ARCH ?= $(BUILDARCH)

# canonicalized names for target architecture
ifeq ($(ARCH),aarch64)
	override ARCH=arm64
endif
ifeq ($(ARCH),x86_64)
	override ARCH=amd64
endif

# we want to be able to run the same recipe on multiple targets keyed on the image name
# to do that, we would use the entire image name, e.g. calico/node:abcdefg, as the stem, or '%', in the target
# however, make does **not** allow the usage of invalid filename characters - like / and : - in a stem, and thus errors out
# to get around that, we "escape" those characters by converting all : to --- and all / to ___ , so that we can use them
# in the target, we then unescape them back
escapefs = $(subst :,---,$(subst /,___,$(1)))
unescapefs = $(subst ---,:,$(subst ___,/,$(1)))

# these macros create a list of valid architectures for pushing manifests
space :=
space +=
comma := ,
prefix_linux = $(addprefix linux/,$(strip $1))
join_platforms = $(subst $(space),$(comma),$(call prefix_linux,$(strip $1)))

# list of arches *not* to build when doing *-all
#    until s390x works correctly
EXCLUDEARCH ?= s390x
VALIDARCHES = $(filter-out $(EXCLUDEARCH),$(ARCHES))

###############################################################################
GO_BUILD_VER?=v0.49
CALICO_BUILD?=calico/go-build:$(GO_BUILD_VER)
PROTOC_VER?=v0.1
PROTOC_CONTAINER?=calico/protoc:$(PROTOC_VER)-$(BUILDARCH)

# Get version from git - used for releases.
GIT_VERSION?=$(shell git describe --tags --dirty --always --abbrev=12)
ifeq ($(LOCAL_BUILD),true)
	GIT_VERSION = $(shell git describe --tags --dirty --always --abbrev=12)-dev-build
endif

# Figure out the users UID/GID.  These are needed to run docker containers
# as the current user and ensure that files built inside containers are
# owned by the current user.
LOCAL_USER_ID:=$(shell id -u)
MY_GID:=$(shell id -g)

SRC_FILES=$(shell find -name '*.go' |grep -v vendor)

# If local build is set, then always build the binary since we might not
# detect when another local repository has been modified.
ifeq ($(LOCAL_BUILD),true)
.PHONY: $(SRC_FILES)
endif

############################################################################
PACKAGE_NAME?=github.com/envoyproxy/data-plane-api

# If this is a release, also tag and push additional images.
ifeq ($(RELEASE),true)
PUSH_IMAGES+=$(RELEASE_IMAGES)
endif

# remove from the list to push to manifest any registries that do not support multi-arch
EXCLUDE_MANIFEST_REGISTRIES ?= quay.io/
PUSH_MANIFEST_IMAGES=$(PUSH_IMAGES:$(EXCLUDE_MANIFEST_REGISTRIES)%=)
PUSH_NONMANIFEST_IMAGES=$(filter-out $(PUSH_MANIFEST_IMAGES),$(PUSH_IMAGES))

# location of docker credentials to push manifests
DOCKER_CONFIG ?= $(HOME)/.docker/config.json

BUILD_FLAGS		+= -mod=vendor
GINKGO_ARGS		+= -mod=vendor

# Allow the ssh auth sock to be mapped into the build container.
ifdef SSH_AUTH_SOCK
	EXTRA_DOCKER_ARGS += -v $(SSH_AUTH_SOCK):/ssh-agent --env SSH_AUTH_SOCK=/ssh-agent
endif

# Volume-mount gopath into the build container to cache go module's packages. If the environment is using multiple
# comma-separated directories for gopath, use the first one, as that is the default one used by go modules.
ifneq ($(GOPATH),)
	# If the environment is using multiple comma-separated directories for gopath, use the first one, as that
	# is the default one used by go modules.
	GOMOD_CACHE = $(shell echo $(GOPATH) | cut -d':' -f1)/pkg/mod
else
	# If gopath is empty, default to $(HOME)/go.
	GOMOD_CACHE = $(HOME)/go/pkg/mod
endif

EXTRA_DOCKER_ARGS	+= -e GO111MODULE=on -v $(GOMOD_CACHE):/go/pkg/mod:rw

# Build mounts for running in "local build" mode. This allows an easy build using local development code,
# assuming that there is a local checkout of libcalico in the same directory as this repo.
PHONY:local_build

ifdef LOCAL_BUILD
EXTRA_DOCKER_ARGS+=-v $(CURDIR)/../libcalico-go:/go/src/github.com/projectcalico/libcalico-go:rw
local_build:
	$(DOCKER_RUN) $(CALICO_BUILD) go mod edit -replace=github.com/projectcalico/libcalico-go=../libcalico-go
else
local_build:
	@echo "Building app-policy"
endif

DOCKER_RUN := mkdir -p .go-pkg-cache $(GOMOD_CACHE) && \
	docker run --rm \
		--net=host \
		$(EXTRA_DOCKER_ARGS) \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		-e GOCACHE=/go-cache \
		-e GOARCH=$(ARCH) \
		-e GOPATH=/go \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME):rw \
		-v $(CURDIR)/.go-pkg-cache:/go-cache:rw \
		-w /go/src/$(PACKAGE_NAME)

DOCKER_RUN_RO := mkdir -p .go-pkg-cache $(GOMOD_CACHE) && \
	docker run --rm \
		--net=host \
		$(EXTRA_DOCKER_ARGS) \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		-e GOCACHE=/go-cache \
		-e GOARCH=$(ARCH) \
		-e GOPATH=/go \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME):ro \
		-v $(CURDIR)/.go-pkg-cache:/go-cache:rw \
		-w /go/src/$(PACKAGE_NAME)

DOCKER_RUN_PB := docker run --rm \
		$(EXTRA_DOCKER_ARGS) \
		--user $(LOCAL_USER_ID):$(MY_GID) \
		-v $(CURDIR):/code

ENVOY_API=.
EXT_AUTH=$(ENVOY_API)/envoy/service/auth/v2/
EXT_AUTH_V2_ALPHA=$(ENVOY_API)/envoy/service/auth/v2alpha/
ADDRESS=$(ENVOY_API)/envoy/api/v2/core/address
V2_BASE=$(ENVOY_API)/envoy/api/v2/core/base
HTTP_STATUS=$(ENVOY_API)/envoy/type/http_status
PERCENT=$(ENVOY_API)/envoy/type/percent

.PHONY: clean
## Clean enough that a new release build will be clean
clean:
	rm -rf .go-pkg-cache
	find . -name '*.created-$(ARCH)' -exec rm -f {} +
	rm -rf report vendor

# We use gogofast for protobuf compilation.  Regular gogo is incompatible with
# gRPC, since gRPC uses golang/protobuf for marshalling/unmarshalling in that
# case.  See https://github.com/gogo/protobuf/issues/386 for more details.
# Note that we cannot seem to use gogofaster because of incompatibility with
# Envoy's validation library.
# When importing, we must use gogo versions of google/protobuf and
# google/rpc (aka googleapis).
PROTOC_IMPORTS =  -I $(ENVOY_API) \
		  -I /go/pkg \
		  -I /go/pkg/mod/github.com/envoyproxy/protoc-gen-validate@v0.4.1/ \
		  -I /go/pkg/mod/github.com/gogo/protobuf@v1.3.2/ \
		  -I /go/pkg/mod/github.com/cncf/udpa@v0.0.1/ \
		  -I /go/pkg/mod/github.com/golang/protobuf@v1.4.3/ \
		  -I /go/pkg/mod/github.com/googleapis/googleapis@v0.0.0-20210121202636-cb932c5caa75

# Also remap the output modules to gogo versions of google/protobuf and google/rpc
PROTOC_MAPPINGS = Menvoy/api/v2/core/address.proto=github.com/envoyproxy/data-plane-api/envoy/api/v2/core,Menvoy/api/v2/core/base.proto=github.com/envoyproxy/data-plane-api/envoy/api/v2/core,Menvoy/type/http_status.proto=github.com/envoyproxy/data-plane-api/envoy/type,Menvoy/type/percent.proto=github.com/envoyproxy/data-plane-api/envoy/type,Mgogoproto/gogo.proto=github.com/gogo/protobuf/gogoproto,Mgoogle/protobuf/any.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/duration.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/struct.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/timestamp.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/wrappers.proto=github.com/gogo/protobuf/types,Mgoogle/rpc/status.proto=github.com/gogo/googleapis/google/rpc,Menvoy/service/auth/v2/external_auth.proto=github.com/envoyproxy/data-plane-api/envoy/service/auth/v2

proto: $(EXT_AUTH)external_auth.pb.go $(EXT_AUTH_V2_ALPHA)external_auth.pb.go $(ADDRESS).pb.go $(V2_BASE).pb.go $(HTTP_STATUS).pb.go $(PERCENT).pb.go $(EXT_AUTH)attribute_context.pb.go

$(EXT_AUTH)external_auth.pb.go $(EXT_AUTH)attribute_context.pb.go: $(EXT_AUTH)external_auth.proto $(EXT_AUTH)attribute_context.proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(EXT_AUTH)*.proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(EXT_AUTH_V2_ALPHA)external_auth.pb.go: $(EXT_AUTH_V2_ALPHA)external_auth.proto
	@go mod download
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(EXT_AUTH_V2_ALPHA)*.proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(ADDRESS).pb.go $(V2_BASE).pb.go: $(ADDRESS).proto $(V2_BASE).proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(ADDRESS).proto $(V2_BASE).proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(HTTP_STATUS).pb.go: $(HTTP_STATUS).proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(HTTP_STATUS).proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(PERCENT).pb.go: $(PERCENT).proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(PERCENT).proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(EXT_AUTH)external_auth.proto $(EXT_AUTH_V2_ALPHA)external_auth.proto $(ADDRESS).proto $(V2_BASE).proto $(HTTP_STATUS).proto $(PERCENT).proto $(EXT_AUTH)attribute_context.proto:

proto/felixbackend.pb.go: proto/felixbackend.proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      proto/*.proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):proto

proto/healthz.pb.go: proto/healthz.proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      proto/*.proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):proto

###############################################################################
# Developer helper scripts (not used by build or test)
###############################################################################
.PHONY: help
## Display this help text
help: # Some kind of magic from https://gist.github.com/rcmachado/af3db315e31383502660
	@awk '/^[a-zA-Z\-\_0-9\/]+:/ {				      \
		nb = sub( /^## /, "", helpMsg );				\
		if(nb == 0) {						   \
			helpMsg = $$0;					      \
			nb = sub( /^[^:]*:.* ## /, "", helpMsg );		   \
		}							       \
		if (nb)							 \
			printf "\033[1;31m%-" width "s\033[0m %s\n", $$1, helpMsg;  \
	}								   \
	{ helpMsg = $$0 }'						  \
	width=20							    \
	$(MAKEFILE_LIST)
