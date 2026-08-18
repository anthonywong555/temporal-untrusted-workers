# Container image builds via ko (https://ko.build) for the Go binaries and
# docker buildx for the TypeScript worker.
#
# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
#   LOCAL=1 (default)  Build for a single platform and load into the local
#                      Docker daemon. No registry, no push, no login.
#                      Default repo is ko.local.
#   LOCAL=0            Build multi-platform and push to KO_DOCKER_REPO.
#
# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
#   LOCAL           1 = load locally, 0 = push. Default 1.
#   PLATFORM        Single target platform, e.g. linux/amd64. Overrides the
#                   default for the current mode. Use PLATFORMS for a list.
#   PLATFORMS       Comma-separated platform list. Defaults to the host
#                   platform when LOCAL=1, or linux/amd64,linux/arm64 when
#                   LOCAL=0.
#   IMAGE_NAME      Override the image name for whichever single target you
#                   are building, e.g.
#                     make image-proxy IMAGE_NAME=my-proxy
#                   For `make images`, set the per-image variables instead:
#                   PROXY_IMAGE, WORKER_IMAGE, WORKER_TS_IMAGE.
#   BUILD_ID        Build identifier. Applied as an extra image tag AND as the
#                   org.opencontainers.image.revision label. Defaults to the
#                   short git SHA. Pass BUILD_ID= (empty) to disable.
#   TAGS            Primary tag(s), comma-separated. Default latest.
#   KO_DOCKER_REPO  Base registry/repo. Required when LOCAL=0.
#   KO              Path to the ko binary, or e.g.
#                   KO="go run github.com/google/ko@latest".
#
# ---------------------------------------------------------------------------
# Examples
# ---------------------------------------------------------------------------
#   make images
#   make image-proxy PLATFORM=linux/amd64
#   make image-proxy PLATFORM=linux/amd64 IMAGE_NAME=temporal-proxy-dev BUILD_ID=1234
#   make image-verify-worker-ts PLATFORM=linux/amd64 TAGS=dev
#   make images LOCAL=0 KO_DOCKER_REPO=ghcr.io/02strich/temporal-untrusted-workers TAGS=v0.1.0
#
# ---------------------------------------------------------------------------
# Notes
# ---------------------------------------------------------------------------
# examples/verify-worker lives in its own Go module (examples/go.mod - it
# depends on an older go.temporal.io/sdk that conflicts with this module's
# go.temporal.io/api version), so its build runs with examples/ as the
# working directory.
#
# examples/verify-worker-ts is a TypeScript/npm project - ko only builds Go
# import paths, so it uses docker buildx and shares the same variables.
#
# Building linux/amd64 on an arm64 Mac: ko cross-compiles natively, but the
# buildx build for verify-worker-ts runs npm inside an amd64 container and
# therefore needs emulation (Docker Desktop's Rosetta option, or QEMU).

KO ?= ko
TAGS ?= latest
LOCAL ?= 1
IMAGE_SOURCE := https://github.com/02strich/temporal-untrusted-workers
COMMA := ,

# Default image names. IMAGE_NAME overrides whichever one you're building.
PROXY_IMAGE     ?= $(if $(IMAGE_NAME),$(IMAGE_NAME),temporal-proxy)
WORKER_IMAGE    ?= $(if $(IMAGE_NAME),$(IMAGE_NAME),verify-worker)
WORKER_TS_IMAGE ?= $(if $(IMAGE_NAME),$(IMAGE_NAME),verify-worker-ts)

# Build ID defaults to the short git SHA. `BUILD_ID=` disables it entirely.
ifeq ($(origin BUILD_ID), undefined)
  BUILD_ID := $(shell git rev-parse --short HEAD 2>/dev/null)
endif

# ---------------------------------------------------------------------------
# Host platform detection (default target platform when LOCAL=1).
# ---------------------------------------------------------------------------
HOST_ARCH := $(shell uname -m)
ifeq ($(HOST_ARCH),x86_64)
  HOST_PLATFORM := linux/amd64
else ifeq ($(HOST_ARCH),amd64)
  HOST_PLATFORM := linux/amd64
else
  HOST_PLATFORM := linux/arm64
endif

DEFAULT_PUSH_PLATFORMS := linux/amd64,linux/arm64

# ---------------------------------------------------------------------------
# Mode-dependent settings. Multi-platform output can't be loaded into the
# classic Docker image store, so LOCAL=1 builds one platform and uses
# --load / ko --local; LOCAL=0 pushes and needs a docker-container builder.
# ---------------------------------------------------------------------------
ifeq ($(LOCAL),1)
  PLATFORMS ?= $(if $(PLATFORM),$(PLATFORM),$(HOST_PLATFORM))
  KO_DOCKER_REPO ?= ko.local
  KO_FLAGS := --local
  DOCKER_OUTPUT := --load
  BUILDX_FLAGS :=
  REPO_CHECK :=
  TS_DEPS := check-single-platform
  KO_DEPS := check-single-platform
else
  PLATFORMS ?= $(if $(PLATFORM),$(PLATFORM),$(DEFAULT_PUSH_PLATFORMS))
  KO_FLAGS :=
  DOCKER_OUTPUT := --push
  BUILDX_BUILDER ?= multiarch
  BUILDX_FLAGS := --builder=$(BUILDX_BUILDER)
  REPO_CHECK := check-repo
  TS_DEPS := buildx-setup
  KO_DEPS :=
endif

# ---------------------------------------------------------------------------
# Tags and labels. BUILD_ID becomes an additional tag when set.
# ---------------------------------------------------------------------------
ALL_TAGS := $(if $(BUILD_ID),$(TAGS)$(COMMA)$(BUILD_ID),$(TAGS))
TAG_LIST := $(subst $(COMMA), ,$(ALL_TAGS))

KO_LABELS := --image-label=org.opencontainers.image.source=$(IMAGE_SOURCE) \
	$(if $(BUILD_ID),--image-label=org.opencontainers.image.revision=$(BUILD_ID))

DOCKER_LABELS := --label org.opencontainers.image.source=$(IMAGE_SOURCE) \
	$(if $(BUILD_ID),--label org.opencontainers.image.revision=$(BUILD_ID))

TS_TAG_FLAGS := $(foreach t,$(TAG_LIST),-t $(KO_DOCKER_REPO)/$(WORKER_TS_IMAGE):$(t))

.PHONY: images image-proxy image-verify-worker image-verify-worker-ts \
        ko-install buildx-setup check-ko check-docker check-repo \
        check-single-platform print-config

images: image-proxy image-verify-worker image-verify-worker-ts

# ko's --bare publishes to exactly KO_DOCKER_REPO with no derived suffix,
# which is what allows the image name to be overridden. (The previous
# --base-import-paths derived the name from the Go package and is mutually
# exclusive with --bare.)
image-proxy: check-ko $(REPO_CHECK) $(KO_DEPS)
	KO_DOCKER_REPO=$(KO_DOCKER_REPO)/$(PROXY_IMAGE) $(KO) build \
		$(KO_FLAGS) \
		--bare \
		--platform=$(PLATFORMS) \
		--tags=$(ALL_TAGS) \
		$(KO_LABELS) \
		./cmd/temporal-proxy

image-verify-worker: check-ko $(REPO_CHECK) $(KO_DEPS)
	cd examples && KO_DOCKER_REPO=$(KO_DOCKER_REPO)/$(WORKER_IMAGE) $(KO) build \
		$(KO_FLAGS) \
		--bare \
		--platform=$(PLATFORMS) \
		--tags=$(ALL_TAGS) \
		$(KO_LABELS) \
		./verify-worker

image-verify-worker-ts: check-docker $(REPO_CHECK) $(TS_DEPS)
	docker buildx build \
		$(BUILDX_FLAGS) \
		--platform=$(PLATFORMS) \
		$(DOCKER_OUTPUT) \
		$(TS_TAG_FLAGS) \
		$(DOCKER_LABELS) \
		examples/verify-worker-ts

ko-install:
	go install github.com/google/ko@latest

# Multi-platform buildx output needs the docker-container driver; the default
# "docker" driver writes to the legacy image store and handles one platform.
buildx-setup: check-docker
	@docker buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1 || \
		docker buildx create --name $(BUILDX_BUILDER) --driver docker-container --bootstrap

check-ko:
	@command -v $(firstword $(KO)) >/dev/null 2>&1 || { echo "ko not found on PATH - install it with 'make ko-install', 'brew install ko', 'flox install ko', or see https://ko.build/install/"; exit 1; }

check-docker:
	@command -v docker >/dev/null 2>&1 || { echo "docker not found on PATH - install Docker/OrbStack and ensure it is running"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "docker is installed but the daemon is not reachable - start Docker Desktop/OrbStack and retry"; exit 1; }

check-single-platform:
	@case "$(PLATFORMS)" in \
		*,*) echo "LOCAL=1 can only load a single platform into the Docker daemon (got PLATFORMS=$(PLATFORMS)). Use PLATFORM=linux/amd64, or set LOCAL=0 to build multi-platform and push."; exit 1 ;; \
	esac

check-repo:
	@test -n "$(KO_DOCKER_REPO)" || { echo "KO_DOCKER_REPO must be set when LOCAL=0, e.g. make images LOCAL=0 KO_DOCKER_REPO=ghcr.io/02strich/temporal-untrusted-workers"; exit 1; }

print-config:
	@echo "LOCAL=$(LOCAL)"
	@echo "PLATFORMS=$(PLATFORMS)"
	@echo "KO_DOCKER_REPO=$(KO_DOCKER_REPO)"
	@echo "BUILD_ID=$(BUILD_ID)"
	@echo "tags=$(ALL_TAGS)"
	@echo "proxy:     $(foreach t,$(TAG_LIST),$(KO_DOCKER_REPO)/$(PROXY_IMAGE):$(t))"
	@echo "worker:    $(foreach t,$(TAG_LIST),$(KO_DOCKER_REPO)/$(WORKER_IMAGE):$(t))"
	@echo "worker-ts: $(foreach t,$(TAG_LIST),$(KO_DOCKER_REPO)/$(WORKER_TS_IMAGE):$(t))"