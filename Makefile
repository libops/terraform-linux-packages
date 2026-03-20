.PHONY: package download-release-assets publish-package-repo package-tools-image package-tools-image-local create-aptly-gpg-key print-aptly-gpg-key-id sync-aptly-gpg-key-id

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TFVARS_PATH ?= $(ROOT_DIR)/terraform.tfvars
VARIABLES_TF_PATH ?= $(ROOT_DIR)/variables.tf
PROJECT_ID_DEFAULT := $(shell sed -n '/^variable "project_id"[[:space:]]*{/,/^}/s/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$(VARIABLES_TF_PATH)" 2>/dev/null | head -n1)
BUCKET_NAME_DEFAULT := $(shell sed -n '/^variable "bucket_name"[[:space:]]*{/,/^}/s/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$(VARIABLES_TF_PATH)" 2>/dev/null | head -n1)
APTLY_GPG_KEY_ID_DEFAULT := $(shell sed -n '/^variable "aptly_gpg_key_id"[[:space:]]*{/,/^}/s/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$(VARIABLES_TF_PATH)" 2>/dev/null | head -n1)
DIST_DIR ?= $(ROOT_DIR)/.dist/$(PACKAGE_NAME)/$(RELEASE_VERSION)
GCLOUD_PROJECT ?= $(or $(shell sed -n 's/^project_id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$(TFVARS_PATH)" 2>/dev/null | head -n1),$(PROJECT_ID_DEFAULT))
GCS_BUCKET ?= $(or $(shell sed -n 's/^bucket_name[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$(TFVARS_PATH)" 2>/dev/null | head -n1),$(BUCKET_NAME_DEFAULT))
APTLY_GPG_KEY_ID ?= $(or $(shell sed -n 's/^aptly_gpg_key_id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$(TFVARS_PATH)" 2>/dev/null | head -n1),$(APTLY_GPG_KEY_ID_DEFAULT))
APTLY_GPG_PRIVATE_KEY_SECRET ?= aptly-gpg-private-key
APTLY_GPG_PASSPHRASE_SECRET ?= aptly-gpg-passphrase
APTLY_DISTRIBUTIONS ?= bookworm
APTLY_COMPONENT ?= main
APTLY_ARCHITECTURES ?= amd64,arm64
APTLY_PUBLISH_PREFIX ?= .
APTLY_ORIGIN ?= libops
RPM_REPOSITORY_PATH ?= rpm
PACKAGE_REPO_STAGE_DIR ?= $(ROOT_DIR)/.out/$(PACKAGE_NAME)/$(RELEASE_VERSION)
PACKAGE_TOOLS_IMAGE ?= ghcr.io/libops/terraform-linux-packages:main
HOST_GCLOUD_CONFIG ?= $(if $(CLOUDSDK_CONFIG),$(CLOUDSDK_CONFIG),$(HOME)/.config/gcloud)
GCLOUD_CREDENTIALS_FILE ?= $(or $(CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE),$(GOOGLE_APPLICATION_CREDENTIALS))
APTLY_GPG_NAME ?= libops packages
APTLY_GPG_EMAIL ?= packages@libops.io
APTLY_GPG_KEY_EXPIRE ?= 2y
APTLY_GPG_ARTIFACTS_DIR ?= $(ROOT_DIR)/.out/gpg

package: download-release-assets publish-package-repo

package-tools-image:
	docker pull "$(PACKAGE_TOOLS_IMAGE)"

package-tools-image-local:
	docker build -t "$(PACKAGE_TOOLS_IMAGE)" -f "$(ROOT_DIR)/Dockerfile" "$(ROOT_DIR)"

create-aptly-gpg-key:
	@test -n "$(GCLOUD_PROJECT)" || (echo "GCLOUD_PROJECT is required" && exit 1)
	@mkdir -p "$(APTLY_GPG_ARTIFACTS_DIR)"; \
	docker image inspect "$(PACKAGE_TOOLS_IMAGE)" >/dev/null 2>&1 || $(MAKE) package-tools-image; \
	docker run --rm -i \
		-v "$(ROOT_DIR):/workspace/terraform-linux-packages" \
		-v "$(APTLY_GPG_ARTIFACTS_DIR):$(APTLY_GPG_ARTIFACTS_DIR)" \
		-v "$(HOST_GCLOUD_CONFIG):/root/.config/gcloud" \
		$(if $(GCLOUD_CREDENTIALS_FILE),-v "$(GCLOUD_CREDENTIALS_FILE):$(GCLOUD_CREDENTIALS_FILE):ro") \
		-e GOOGLE_APPLICATION_CREDENTIALS="$(GOOGLE_APPLICATION_CREDENTIALS)" \
		-e CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$(GCLOUD_CREDENTIALS_FILE)" \
		-e GCLOUD_PROJECT="$(GCLOUD_PROJECT)" \
		-e APTLY_GPG_PRIVATE_KEY_SECRET="$(APTLY_GPG_PRIVATE_KEY_SECRET)" \
		-e APTLY_GPG_PASSPHRASE_SECRET="$(APTLY_GPG_PASSPHRASE_SECRET)" \
		-e APTLY_GPG_NAME="$(APTLY_GPG_NAME)" \
		-e APTLY_GPG_EMAIL="$(APTLY_GPG_EMAIL)" \
		-e APTLY_GPG_KEY_EXPIRE="$(APTLY_GPG_KEY_EXPIRE)" \
		-e APTLY_GPG_ARTIFACTS_DIR="$(APTLY_GPG_ARTIFACTS_DIR)" \
		"$(PACKAGE_TOOLS_IMAGE)" \
		/bin/bash /workspace/terraform-linux-packages/scripts/create-aptly-gpg-key.sh

print-aptly-gpg-key-id:
	@test -n "$(GCLOUD_PROJECT)" || (echo "GCLOUD_PROJECT is required" && exit 1)
	@docker image inspect "$(PACKAGE_TOOLS_IMAGE)" >/dev/null 2>&1 || $(MAKE) package-tools-image; \
	docker run --rm \
		-v "$(ROOT_DIR):/workspace/terraform-linux-packages" \
		-v "$(HOST_GCLOUD_CONFIG):/root/.config/gcloud" \
		$(if $(GCLOUD_CREDENTIALS_FILE),-v "$(GCLOUD_CREDENTIALS_FILE):$(GCLOUD_CREDENTIALS_FILE):ro") \
		-e GOOGLE_APPLICATION_CREDENTIALS="$(GOOGLE_APPLICATION_CREDENTIALS)" \
		-e CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$(GCLOUD_CREDENTIALS_FILE)" \
		-e GCLOUD_PROJECT="$(GCLOUD_PROJECT)" \
		-e APTLY_GPG_PRIVATE_KEY_SECRET="$(APTLY_GPG_PRIVATE_KEY_SECRET)" \
		"$(PACKAGE_TOOLS_IMAGE)" \
		/bin/bash /workspace/terraform-linux-packages/scripts/resolve-aptly-gpg-key-id.sh

sync-aptly-gpg-key-id:
	@test -f "$(TFVARS_PATH)" || (echo "terraform tfvars file not found: $(TFVARS_PATH)" && exit 1)
	@KEY_ID="$$( $(MAKE) --no-print-directory print-aptly-gpg-key-id )"; \
	if [ $$? -ne 0 ] || [ -z "$$KEY_ID" ]; then \
		echo "Unable to resolve aptly GPG key ID"; \
		exit 1; \
	fi; \
	case "$$KEY_ID" in *"GCLOUD_PROJECT is required"*|*"command not found"* ) \
		echo "Unable to resolve aptly GPG key ID"; \
		exit 1; \
	;; esac; \
	TMP_FILE="$$(mktemp)"; \
	awk -v key_id="$$KEY_ID" '\
		BEGIN { updated = 0 } \
		/^aptly_gpg_key_id[[:space:]]*=/ { print "aptly_gpg_key_id = \"" key_id "\""; updated = 1; next } \
		{ print } \
		END { if (!updated) print "aptly_gpg_key_id = \"" key_id "\"" } \
	' "$(TFVARS_PATH)" > "$$TMP_FILE"; \
	mv "$$TMP_FILE" "$(TFVARS_PATH)"; \
	echo "Set aptly_gpg_key_id to $$KEY_ID in $(TFVARS_PATH)"

download-release-assets:
	@test -n "$(GITHUB_REPOSITORY)" || (echo "GITHUB_REPOSITORY is required" && exit 1)
	@test -n "$(RELEASE_VERSION)" || (echo "RELEASE_VERSION is required" && exit 1)
	@mkdir -p "$(DIST_DIR)"
	@PACKAGE_NAME_VALUE="$(PACKAGE_NAME)"; \
	if [ -z "$$PACKAGE_NAME_VALUE" ]; then \
		PACKAGE_NAME_VALUE="$${GITHUB_REPOSITORY##*/}"; \
	fi; \
	GITHUB_REPOSITORY="$(GITHUB_REPOSITORY)" \
	RELEASE_VERSION="$(RELEASE_VERSION)" \
	DIST_DIR="$(DIST_DIR)" \
	PACKAGE_NAME="$$PACKAGE_NAME_VALUE" \
	/bin/bash "$(ROOT_DIR)/scripts/download-release-assets.sh"

publish-package-repo:
	@test -n "$(GCLOUD_PROJECT)" || (echo "GCLOUD_PROJECT is required" && exit 1)
	@test -n "$(GCS_BUCKET)" || (echo "GCS_BUCKET is required" && exit 1)
	@test -n "$(APTLY_GPG_KEY_ID)" || (echo "APTLY_GPG_KEY_ID is required" && exit 1)
	@mkdir -p "$(PACKAGE_REPO_STAGE_DIR)"; \
	PACKAGE_NAME_VALUE="$(PACKAGE_NAME)"; \
	if [ -z "$$PACKAGE_NAME_VALUE" ]; then \
		PACKAGE_NAME_VALUE="$${GITHUB_REPOSITORY##*/}"; \
	fi; \
	docker image inspect "$(PACKAGE_TOOLS_IMAGE)" >/dev/null 2>&1 || $(MAKE) package-tools-image; \
	docker run --rm \
		-v "$(ROOT_DIR):/workspace/terraform-linux-packages" \
		-v "$(DIST_DIR):$(DIST_DIR)" \
		-v "$(PACKAGE_REPO_STAGE_DIR):$(PACKAGE_REPO_STAGE_DIR)" \
		-v "$(HOST_GCLOUD_CONFIG):/root/.config/gcloud" \
		$(if $(GCLOUD_CREDENTIALS_FILE),-v "$(GCLOUD_CREDENTIALS_FILE):$(GCLOUD_CREDENTIALS_FILE):ro") \
		-e GOOGLE_APPLICATION_CREDENTIALS="$(GOOGLE_APPLICATION_CREDENTIALS)" \
		-e CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$(GCLOUD_CREDENTIALS_FILE)" \
		-e GCLOUD_PROJECT="$(GCLOUD_PROJECT)" \
		-e GCS_BUCKET="$(GCS_BUCKET)" \
		-e GCS_BUCKET_PREFIX="$(if $(GCS_BUCKET_PREFIX),$(GCS_BUCKET_PREFIX),$$PACKAGE_NAME_VALUE)" \
		-e DIST_DIR="$(DIST_DIR)" \
		-e PACKAGE_NAME="$$PACKAGE_NAME_VALUE" \
		-e APTLY_GPG_KEY_ID="$(APTLY_GPG_KEY_ID)" \
		-e APTLY_GPG_PRIVATE_KEY_SECRET="$(APTLY_GPG_PRIVATE_KEY_SECRET)" \
		-e APTLY_GPG_PASSPHRASE_SECRET="$(APTLY_GPG_PASSPHRASE_SECRET)" \
		-e APTLY_DISTRIBUTIONS="$(APTLY_DISTRIBUTIONS)" \
		-e APTLY_COMPONENT="$(APTLY_COMPONENT)" \
		-e APTLY_ARCHITECTURES="$(APTLY_ARCHITECTURES)" \
		-e APTLY_PUBLISH_PREFIX="$(APTLY_PUBLISH_PREFIX)" \
		-e APTLY_ORIGIN="$(APTLY_ORIGIN)" \
		-e APTLY_LABEL="$(if $(APTLY_LABEL),$(APTLY_LABEL),$$PACKAGE_NAME_VALUE)" \
		-e APTLY_PUBLIC_KEY_NAME="$(if $(APTLY_PUBLIC_KEY_NAME),$(APTLY_PUBLIC_KEY_NAME),$$PACKAGE_NAME_VALUE-archive-keyring)" \
		-e RPM_REPOSITORY_PATH="$(RPM_REPOSITORY_PATH)" \
		-e PACKAGE_REPO_STAGE_DIR="$(PACKAGE_REPO_STAGE_DIR)" \
		"$(PACKAGE_TOOLS_IMAGE)" \
		/bin/bash /workspace/terraform-linux-packages/scripts/publish-package-repo.sh
docs:
	terraform-docs markdown table --output-file README.md .
