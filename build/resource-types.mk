# ------------------------------------------------------------
# Copyright 2023 The Radius Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ------------------------------------------------------------

# resource-types.mk provides targets for synchronizing default resource type
# manifests from the resource-types-contrib repository.
#
# resource-types-contrib contains only YAML manifests and HCL/Bicep recipes -
# no executable Go code. Rather than vendoring it as a Go module, the manifests
# are fetched directly from a pinned upstream git revision recorded in
# deploy/manifest/defaults.yaml (source.repo / source.ref).
#
# How it works:
#   1. defaults.yaml records the upstream source (source.repo, source.ref) and
#      lists which resource types to ship as defaults, using <namespace>/<typeName>
#      names (e.g. Radius.Compute/containers).
#   2. sync-resource-types performs a shallow git fetch of source.ref into a
#      temporary directory.
#   3. Each entry is resolved to a file path in the fetched tree:
#        Radius.Compute/containers → Compute/containers/containers.yaml
#      (strip "Radius." prefix, then <namespace>/<typeName>/<typeName>.yaml)
#   4. The resolved file is copied into both dev/ and self-hosted/ directories
#      under deploy/manifest/built-in-providers/.
#   5. At startup, UCP's RegisterDirectory loads these files. Manifests without
#      a "location" field are routed via DefaultDownstreamEndpoint (dynamic-rp).
#
# Targets:
#   update-resource-types  - Resolve RESOURCE_TYPES_REF (default "main") to an
#                            immutable commit SHA, pin it in defaults.yaml
#                            (source.ref), and copy the manifest files.
#   sync-resource-types    - Copy manifest files from the ref already pinned in
#                            defaults.yaml (no ref bump). Used by CI to verify
#                            that committed copies match the pinned ref.

# Path to the file listing default resource types and the upstream source pin.
DEFAULTS_YAML := deploy/manifest/defaults.yaml

# Directories where manifest copies are placed. Both directories contain the
# same set of files; dev/ is used for local development (endpoints point to
# localhost) and self-hosted/ is used for Kubernetes deployments.
# Note: The copied manifests themselves have no "location" field. The location
# is only present in the manually maintained files (radius_core.yaml, etc.).
MANIFEST_DEST_DIRS := deploy/manifest/built-in-providers/dev deploy/manifest/built-in-providers/self-hosted

# The upstream ref (branch, tag, or commit SHA) that update-resource-types
# resolves to an immutable commit SHA before pinning it in defaults.yaml.
# Defaults to "main" (the moving latest/edge channel). Override to pin a
# release tag or a specific commit, for example:
#   make update-resource-types RESOURCE_TYPES_REF=v0.56.0
RESOURCE_TYPES_REF ?= main
export RESOURCE_TYPES_REF

# Files in the manifest destination directories that are manually maintained
# and should NOT be managed (created or deleted) by the sync target. These are
# resource providers that require explicit location addresses and are not
# sourced from resource-types-contrib.
MANUAL_CORE_MANIFESTS := applications_core.yaml applications_dapr.yaml applications_datastores.yaml applications_messaging.yaml microsoft_resources.yaml radius_core.yaml

##@ Resource Types

.PHONY: update-resource-types
update-resource-types: ## Resolve RESOURCE_TYPES_REF (default main) to a commit SHA, pin it in defaults.yaml, and sync manifest files
	@command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required but not found. Install via: make install-yq"; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "ERROR: git is required but not found."; exit 1; }
	@# Reject refs containing characters outside a conservative allowlist so the
	@# value can be safely interpolated into the git commands below.
	@case "$$RESOURCE_TYPES_REF" in \
		"" ) echo "ERROR: RESOURCE_TYPES_REF must not be empty."; exit 1;; \
		*[!A-Za-z0-9._/-]* ) echo "ERROR: RESOURCE_TYPES_REF '$$RESOURCE_TYPES_REF' contains invalid characters."; exit 1;; \
	esac
	@# Resolve the requested ref to an immutable commit SHA and pin it in
	@# defaults.yaml (source.ref). A 40-char hex value is used as-is; otherwise
	@# the branch/tag is resolved via git ls-remote, preferring the peeled (^{})
	@# commit so annotated tags resolve to their underlying commit.
	@REPO=$$(yq '.source.repo' $(DEFAULTS_YAML)) && \
	if [ -z "$$REPO" ] || [ "$$REPO" = "null" ]; then \
		echo "ERROR: source.repo is not set in $(DEFAULTS_YAML)."; \
		exit 1; \
	fi && \
	echo "Resolving '$$RESOURCE_TYPES_REF' in $$REPO to a commit SHA..." && \
	if echo "$$RESOURCE_TYPES_REF" | grep -Eq '^[0-9a-f]{40}$$'; then \
		sha="$$RESOURCE_TYPES_REF"; \
	else \
		sha=$$(git ls-remote "https://$$REPO.git" "$$RESOURCE_TYPES_REF^{}" | head -n1 | cut -f1); \
		if [ -z "$$sha" ]; then \
			sha=$$(git ls-remote "https://$$REPO.git" "$$RESOURCE_TYPES_REF" | head -n1 | cut -f1); \
		fi; \
	fi && \
	if [ -z "$$sha" ]; then \
		echo "ERROR: Could not resolve ref '$$RESOURCE_TYPES_REF' in $$REPO."; \
		exit 1; \
	fi && \
	echo "  Resolved to $$sha" && \
	yq -i ".source.ref = \"$$sha\"" $(DEFAULTS_YAML)
	@$(MAKE) sync-resource-types

.PHONY: sync-resource-types
sync-resource-types: ## Copy manifest files listed in defaults.yaml from the pinned resource-types-contrib ref
	@# Verify required tools are available before making any changes.
	@command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required but not found. Install via: make install-yq"; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "ERROR: git is required but not found."; exit 1; }
	@echo "Syncing default resource types from resource-types-contrib..."
	@# Read the upstream pin from defaults.yaml, shallow-fetch that exact ref
	@# into a temp directory (removed on exit), then iterate over each entry in
	@# defaults.yaml, convert the resource type name to a repo-relative path
	@# (e.g. Radius.Compute/containers -> Compute/containers/containers.yaml),
	@# and copy the file into each destination directory (dev/ and self-hosted/).
	@REPO=$$(yq '.source.repo' $(DEFAULTS_YAML)) && \
	REF=$$(yq '.source.ref' $(DEFAULTS_YAML)) && \
	if [ -z "$$REPO" ] || [ "$$REPO" = "null" ] || [ -z "$$REF" ] || [ "$$REF" = "null" ]; then \
		echo "ERROR: source.repo and source.ref must be set in $(DEFAULTS_YAML)."; \
		exit 1; \
	fi && \
	echo "  Source: $$REPO @ $$REF" && \
	tmp_dir=$$(mktemp -d) && \
	trap 'rm -rf "$$tmp_dir"' EXIT && \
	git init -q "$$tmp_dir" && \
	git -C "$$tmp_dir" remote add origin "https://$$REPO.git" && \
	if ! git -C "$$tmp_dir" fetch -q --depth 1 origin "$$REF"; then \
		echo "ERROR: Failed to fetch ref '$$REF' from $$REPO."; \
		echo "       source.ref must be a full commit SHA, tag, or branch reachable upstream."; \
		exit 1; \
	fi && \
	git -C "$$tmp_dir" checkout -q FETCH_HEAD && \
	for entry in $$(yq '.defaultRegistration[]' $(DEFAULTS_YAML)); do \
		rel_path=$$(echo "$$entry" | sed 's/^Radius\.//') && \
		type_name=$$(echo "$$rel_path" | cut -d'/' -f2) && \
		src_path="$$tmp_dir/$$rel_path/$$type_name.yaml" && \
		if [ ! -f "$$src_path" ]; then \
			echo "ERROR: File not found: $$rel_path/$$type_name.yaml (from entry '$$entry')"; \
			echo "       Verify the entry in $(DEFAULTS_YAML) and the pinned source.ref."; \
			exit 1; \
		fi && \
		for dest_dir in $(MANIFEST_DEST_DIRS); do \
			cp "$$src_path" "$$dest_dir/$$type_name.yaml"; \
		done && \
		echo "  Copied $$entry"; \
	done
	@# Remove stale managed files: any YAML in the destination directories that
	@# is NOT in MANUAL_CORE_MANIFESTS and NOT in the current defaults.yaml list.
	@# This prevents previously-copied manifests from remaining registered after
	@# their entry is removed from defaults.yaml.
	@EXPECTED_FILES="" && \
	for entry in $$(yq '.defaultRegistration[]' $(DEFAULTS_YAML)); do \
		rel_path=$$(echo "$$entry" | sed 's/^Radius\.//') && \
		type_name=$$(echo "$$rel_path" | cut -d'/' -f2) && \
		EXPECTED_FILES="$$EXPECTED_FILES $$type_name.yaml"; \
	done && \
	for dest_dir in $(MANIFEST_DEST_DIRS); do \
		for file in "$$dest_dir"/*.yaml; do \
			basename=$$(basename "$$file") && \
			is_manual=false && \
			for mc in $(MANUAL_CORE_MANIFESTS); do \
				if [ "$$basename" = "$$mc" ]; then is_manual=true; break; fi; \
			done && \
			if [ "$$is_manual" = "true" ]; then continue; fi && \
			is_expected=false && \
			for ef in $$EXPECTED_FILES; do \
				if [ "$$basename" = "$$ef" ]; then is_expected=true; break; fi; \
			done && \
			if [ "$$is_expected" = "false" ]; then \
				echo "  Removing stale manifest: $$file"; \
				rm "$$file"; \
			fi; \
		done; \
	done
	@echo "Done. Review and commit the updated files."
