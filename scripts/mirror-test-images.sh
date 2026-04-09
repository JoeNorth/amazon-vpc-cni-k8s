#!/usr/bin/env bash
#
# mirror-test-images.sh
#
# Mirrors the integration test images into a private ECR registry so the
# Ginkgo test suite can run without access to the upstream
# 617930562442.dkr.ecr.us-west-2.amazonaws.com registry.
#
# What it does:
#   1. Mirrors public Docker Hub images (busybox, nginx, curl) into ECR
#      under the networking-e2e-test-images/ prefix.
#   2. Mirrors the netcat-openbsd image from public.ecr.aws/eks/.
#   3. Builds the aws-vpc-cni-test-helper image from test/agent/ and pushes it.
#
# Usage:
#   export AWS_ACCOUNT=123456789012
#   export AWS_REGION=us-west-2          # optional, defaults to us-west-2
#   ./scripts/mirror-test-images.sh
#
# After completion, run integration tests with:
#   --test-image-registry=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${AWS_ACCOUNT:?Set AWS_ACCOUNT to your AWS account ID}"
: "${AWS_REGION:=us-west-2}"

ECR_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_PREFIX="networking-e2e-test-images"

# Image tags — keep in sync with test/framework/utils/const.go
TEST_HELPER_TAG="20231212"
BUSYBOX_TAG="latest"
NGINX_TAG="1.25.2"
NETCAT_TAG="v1.0"
CURL_TAG="latest"

PLATFORMS="linux/amd64,linux/arm64"
BUILDX_BUILDER="test-image-mirror"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ensure_ecr_repo() {
    local repo_name="$1"
    if ! aws ecr describe-repositories \
            --repository-names "$repo_name" \
            --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "  Creating ECR repository: $repo_name"
        aws ecr create-repository \
            --repository-name "$repo_name" \
            --region "$AWS_REGION" >/dev/null
    fi
}

ensure_buildx_builder() {
    if ! docker buildx inspect "$BUILDX_BUILDER" >/dev/null 2>&1; then
        echo "Creating buildx builder: $BUILDX_BUILDER"
        docker buildx create --name "$BUILDX_BUILDER" --use >/dev/null
    else
        docker buildx use "$BUILDX_BUILDER"
    fi
}

# Mirror a public image into ECR.
# $1 = source image (e.g. docker.io/library/busybox:latest, public.ecr.aws/eks/...)
# $2 = ECR repo name under the prefix (e.g. busybox)
# $3 = tag
mirror_image() {
    local src="$1"
    local ecr_repo="${ECR_PREFIX}/$2"
    local tag="$3"
    local dest="${ECR_REGISTRY}/${ecr_repo}:${tag}"

    echo "Mirroring ${src} -> ${dest}"
    ensure_ecr_repo "$ecr_repo"

    # Use buildx imagetools to create a multi-arch manifest in ECR directly
    # from the source registry, without pulling layers locally.
    docker buildx imagetools create --tag "$dest" "$src" 2>/dev/null \
        && return 0

    # Fallback: pull, tag, push (single-arch, works if imagetools fails)
    echo "  imagetools failed, falling back to pull/tag/push"
    docker pull "$src"
    docker tag "$src" "$dest"
    docker push "$dest"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "============================================================"
echo " Mirror test images into ECR"
echo " Registry: ${ECR_REGISTRY}"
echo " Prefix:   ${ECR_PREFIX}/"
echo "============================================================"
echo ""

# Authenticate to ECR
echo "Authenticating to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"
echo ""

ensure_buildx_builder

# --- 1. Docker Hub mirrors ---------------------------------------------------

echo "--- Mirroring Docker Hub images ---"
mirror_image "docker.io/library/busybox:${BUSYBOX_TAG}"    "busybox"              "$BUSYBOX_TAG"
mirror_image "docker.io/library/nginx:${NGINX_TAG}"         "nginx"                "$NGINX_TAG"
mirror_image "docker.io/curlimages/curl:${CURL_TAG}"        "curlimages/curl"      "$CURL_TAG"
echo ""

# --- 2. Mirror netcat-openbsd from public ECR ---------------------------------

echo "--- Mirroring netcat-openbsd image ---"
mirror_image "public.ecr.aws/eks/networking-e2e-test-images/netcat-openbsd:${NETCAT_TAG}" "netcat-openbsd" "$NETCAT_TAG"
echo ""

# --- 3. Build aws-vpc-cni-test-helper from source ----------------------------

echo "--- Building aws-vpc-cni-test-helper image ---"
TEST_HELPER_REPO="${ECR_PREFIX}/aws-vpc-cni-test-helper"
TEST_HELPER_DEST="${ECR_REGISTRY}/${TEST_HELPER_REPO}:${TEST_HELPER_TAG}"
ensure_ecr_repo "$TEST_HELPER_REPO"

GOLANG_VERSION=$(cat "${REPO_ROOT}/.go-version")
GOLANG_IMAGE="public.ecr.aws/eks-distro-build-tooling/golang:${GOLANG_VERSION}-gcc-al2"

docker buildx build \
    --platform "$PLATFORMS" \
    --build-arg golang_image="$GOLANG_IMAGE" \
    -t "$TEST_HELPER_DEST" \
    --push \
    "${REPO_ROOT}/test/agent"
echo "Pushed $TEST_HELPER_DEST"
echo ""

# --- Done ---------------------------------------------------------------------

echo "============================================================"
echo " All images pushed. Run tests with:"
echo ""
echo "   --test-image-registry=${ECR_REGISTRY}"
echo "============================================================"
