#!/bin/bash
# Daily beta build: bump version, build Docker, push to registries, create GitHub release
#
# Usage:
#   ./docker-publish-daily-beta.sh <version> [--parallel] [--ghcr-only] [--dockerhub-only] [--skip-release]
#
# Examples:
#   ./docker-publish-daily-beta.sh 0.2.2b2                  # Full release workflow
#   ./docker-publish-daily-beta.sh 0.2.2b2 --parallel       # Build both archs simultaneously
#   ./docker-publish-daily-beta.sh 0.2.2b2 --ghcr-only      # Only push to GHCR
#   ./docker-publish-daily-beta.sh 0.2.2b2 --dockerhub-only # Only push to Docker Hub
#   ./docker-publish-daily-beta.sh 0.2.2b2 --skip-release   # Build+push without GitHub release
#
# This script performs the full daily beta release workflow:
#   1. Validate version (must be beta: X.Y.Zb<N>)
#   2. Bump APP_VERSION in backend/app/core/config.py
#   3. Update CHANGELOG.md date
#   4. Git commit + tag
#   5. Build & push multi-arch Docker images
#   6. Create GitHub prerelease with changelog notes
#   7. Verify manifests and release
#
# Beta versions are never tagged as 'latest'. The in-app update checker uses
# version string parsing (not GitHub's prerelease flag) to detect betas.
#
# Prerequisites:
#   1. Log in to ghcr.io:
#      echo $GITHUB_TOKEN | docker login ghcr.io -u YOUR_USERNAME --password-stdin
#
#   2. Log in to Docker Hub:
#      docker login -u YOUR_USERNAME
#
#   3. GitHub CLI (gh) authenticated for creating releases
#
# Supported architectures:
#   - linux/amd64 (x86_64, most servers/desktops)
#   - linux/arm64 (Raspberry Pi 4/5, Apple Silicon via emulation)

set -e

# Configuration
GHCR_REGISTRY="ghcr.io"
DOCKERHUB_REGISTRY="docker.io"
IMAGE_NAME="maziggy/bambuddy"
GHCR_IMAGE="${GHCR_REGISTRY}/${IMAGE_NAME}"
DOCKERHUB_IMAGE="${DOCKERHUB_REGISTRY}/${IMAGE_NAME}"
PLATFORMS="linux/amd64,linux/arm64"
BUILDER_NAME="bambuddy-builder"
CONFIG_FILE="backend/app/core/config.py"
CHANGELOG_FILE="CHANGELOG.md"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
VERSION=""
PARALLEL=false
PUSH_GHCR=true
PUSH_DOCKERHUB=true
SKIP_RELEASE=false
for arg in "$@"; do
    case $arg in
        --parallel)
            PARALLEL=true
            ;;
        --ghcr-only)
            PUSH_DOCKERHUB=false
            ;;
        --dockerhub-only)
            PUSH_GHCR=false
            ;;
        --skip-release)
            SKIP_RELEASE=true
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$arg"
            fi
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo -e "${YELLOW}Usage: $0 <version> [--parallel] [--ghcr-only] [--dockerhub-only] [--skip-release]${NC}"
    echo ""
    echo "Examples:"
    echo "  $0 0.2.2b2                  # Full release workflow"
    echo "  $0 0.2.2b2 --parallel       # Build both archs simultaneously"
    echo "  $0 0.2.2b2 --ghcr-only      # Only push to GHCR"
    echo "  $0 0.2.2b2 --dockerhub-only # Only push to Docker Hub"
    echo "  $0 0.2.2b2 --skip-release   # Build+push without GitHub release"
    exit 1
fi

# ============================================================
# Step 1: Validate version
# ============================================================
echo -e "${BLUE}[1/7] Validating version...${NC}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+b[0-9]+$ ]]; then
    echo -e "${RED}Error: Version must be a beta version matching X.Y.Zb<N> (e.g., 0.2.2b2)${NC}"
    echo "Got: $VERSION"
    exit 1
fi

# Check for clean working tree
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${RED}Error: Git working tree is not clean. Commit or stash changes first.${NC}"
    git status --short
    exit 1
fi

echo -e "${GREEN}  Version: ${VERSION} (valid beta)${NC}"
echo -e "${GREEN}  Working tree: clean${NC}"

# ============================================================
# Step 2: Bump APP_VERSION in config.py
# ============================================================
echo -e "${BLUE}[2/7] Bumping APP_VERSION...${NC}"

CURRENT_VERSION=$(grep -oP 'APP_VERSION = "\K[^"]+' "$CONFIG_FILE")
echo "  Current: $CURRENT_VERSION"
echo "  New:     $VERSION"

sed -i "s/^APP_VERSION = \".*\"/APP_VERSION = \"${VERSION}\"/" "$CONFIG_FILE"

# Verify the replacement
NEW_VERSION=$(grep -oP 'APP_VERSION = "\K[^"]+' "$CONFIG_FILE")
if [ "$NEW_VERSION" != "$VERSION" ]; then
    echo -e "${RED}Error: Failed to update APP_VERSION in ${CONFIG_FILE}${NC}"
    exit 1
fi
echo -e "${GREEN}  Updated ${CONFIG_FILE}${NC}"

# ============================================================
# Step 3: Update CHANGELOG.md date
# ============================================================
echo -e "${BLUE}[3/7] Updating CHANGELOG.md...${NC}"

TODAY=$(date +%Y-%m-%d)

# Check if the changelog already has this version with a date
if grep -qP "^## \[${VERSION}\] - \d{4}-\d{2}-\d{2}" "$CHANGELOG_FILE"; then
    echo -e "${YELLOW}  CHANGELOG already has ${VERSION} with a date — skipping${NC}"
else
    # Replace "Unreleased" or "Unrelased" (handles typo) for any version header
    sed -i -E "s/^## \[[^]]+\] - Unreleas?ed$/## [${VERSION}] - ${TODAY}/" "$CHANGELOG_FILE"

    # Verify
    if grep -q "^## \[${VERSION}\] - ${TODAY}" "$CHANGELOG_FILE"; then
        echo -e "${GREEN}  Updated to: ## [${VERSION}] - ${TODAY}${NC}"
    else
        echo -e "${YELLOW}  Warning: No 'Unreleased' header found to update${NC}"
        echo "  You may need to manually update CHANGELOG.md"
    fi
fi

# ============================================================
# Step 4: Git commit + tag
# ============================================================
echo -e "${BLUE}[4/7] Creating git commit and tag...${NC}"

git add "$CONFIG_FILE" "$CHANGELOG_FILE"

if git diff --cached --quiet; then
    echo -e "${YELLOW}  No changes to commit (version may already be set)${NC}"
else
    git commit -m "Release v${VERSION}"
    echo -e "${GREEN}  Committed: Release v${VERSION}${NC}"
fi

if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    echo -e "${YELLOW}  Tag v${VERSION} already exists — skipping${NC}"
else
    git tag "v${VERSION}"
    echo -e "${GREEN}  Tagged: v${VERSION}${NC}"
fi

# ============================================================
# Step 5: Build & push Docker images
# ============================================================
echo ""

# Get CPU count
CPU_COUNT=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Building daily beta Docker image${NC}"
echo -e "${GREEN}  Version: ${VERSION}${NC}"
echo -e "${GREEN}  Platforms: ${PLATFORMS}${NC}"
echo -e "${GREEN}  CPU cores: ${CPU_COUNT}${NC}"
if [ "$PARALLEL" = true ]; then
    echo -e "${GREEN}  Mode: PARALLEL (both archs simultaneously)${NC}"
else
    echo -e "${GREEN}  Mode: Sequential (amd64 → arm64)${NC}"
fi
echo -e "${GREEN}  Registries:${NC}"
if [ "$PUSH_GHCR" = true ]; then
    echo -e "${GREEN}    - ${GHCR_IMAGE}${NC}"
fi
if [ "$PUSH_DOCKERHUB" = true ]; then
    echo -e "${GREEN}    - ${DOCKERHUB_IMAGE}${NC}"
fi
echo -e "${GREEN}================================================${NC}"
echo ""

# Check registry logins
if [ "$PUSH_GHCR" = true ]; then
    if ! grep -q "ghcr.io" ~/.docker/config.json 2>/dev/null; then
        echo -e "${YELLOW}Warning: You may not be logged in to ghcr.io${NC}"
        echo "Run: echo \$GITHUB_TOKEN | docker login ghcr.io -u YOUR_USERNAME --password-stdin"
        echo ""
    fi
fi

if [ "$PUSH_DOCKERHUB" = true ]; then
    if ! grep -q "index.docker.io\|docker.io" ~/.docker/config.json 2>/dev/null; then
        echo -e "${RED}Error: You are not logged in to Docker Hub${NC}"
        echo "Run: docker login -u YOUR_USERNAME"
        echo ""
        exit 1
    fi
fi

# Setup buildx builder if not exists
echo -e "${BLUE}[5/7] Setting up Docker Buildx and building...${NC}"
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    echo "Creating new buildx builder: $BUILDER_NAME (optimized for ${CPU_COUNT} cores)"
    docker buildx create \
        --name "$BUILDER_NAME" \
        --driver docker-container \
        --driver-opt network=host \
        --driver-opt "env.BUILDKIT_STEP_LOG_MAX_SIZE=10000000" \
        --buildkitd-flags "--allow-insecure-entitlement network.host --oci-worker-gc=false" \
        --config /dev/stdin <<EOF
[worker.oci]
  max-parallelism = ${CPU_COUNT}
EOF
    docker buildx inspect --bootstrap "$BUILDER_NAME"
fi
docker buildx use "$BUILDER_NAME"

# Verify builder supports multi-platform
if ! docker buildx inspect --bootstrap | grep -q "linux/arm64"; then
    echo -e "${YELLOW}Installing QEMU for cross-platform builds...${NC}"
    docker run --privileged --rm tonistiigi/binfmt --install all
fi

# Beta versions never get 'latest' tag
echo -e "${YELLOW}Beta version — skipping 'latest' tag${NC}"

# Build tags for all target registries
TAGS=""
if [ "$PUSH_GHCR" = true ]; then
    TAGS="$TAGS -t ${GHCR_IMAGE}:${VERSION}"
fi
if [ "$PUSH_DOCKERHUB" = true ]; then
    TAGS="$TAGS -t ${DOCKERHUB_IMAGE}:${VERSION}"
fi

# Common build args (no cache to ensure clean builds)
BUILD_ARGS="--provenance=false --sbom=false --no-cache --pull"

if [ "$PARALLEL" = true ]; then
    # Parallel build: Build each architecture separately then combine manifests
    echo -e "${YELLOW}Building amd64 and arm64 in parallel (${CPU_COUNT} cores each, no cache)...${NC}"

    # Build per-arch staging tags for each target registry
    ARCH_TAGS_AMD64=""
    ARCH_TAGS_ARM64=""
    if [ "$PUSH_GHCR" = true ]; then
        ARCH_TAGS_AMD64="$ARCH_TAGS_AMD64 -t ${GHCR_IMAGE}:${VERSION}-amd64"
        ARCH_TAGS_ARM64="$ARCH_TAGS_ARM64 -t ${GHCR_IMAGE}:${VERSION}-arm64"
    fi
    if [ "$PUSH_DOCKERHUB" = true ]; then
        ARCH_TAGS_AMD64="$ARCH_TAGS_AMD64 -t ${DOCKERHUB_IMAGE}:${VERSION}-amd64"
        ARCH_TAGS_ARM64="$ARCH_TAGS_ARM64 -t ${DOCKERHUB_IMAGE}:${VERSION}-arm64"
    fi

    # Build amd64 in background
    (
        echo -e "${BLUE}[amd64] Starting build...${NC}"
        docker buildx build \
            --platform linux/amd64 \
            ${ARCH_TAGS_AMD64} \
            ${BUILD_ARGS} \
            --push \
            . 2>&1 | sed 's/^/[amd64] /'
        echo -e "${GREEN}[amd64] Complete!${NC}"
    ) &
    PID_AMD64=$!

    # Build arm64 in background
    (
        echo -e "${BLUE}[arm64] Starting build...${NC}"
        docker buildx build \
            --platform linux/arm64 \
            ${ARCH_TAGS_ARM64} \
            ${BUILD_ARGS} \
            --push \
            . 2>&1 | sed 's/^/[arm64] /'
        echo -e "${GREEN}[arm64] Complete!${NC}"
    ) &
    PID_ARM64=$!

    # Wait for both builds
    echo "Waiting for parallel builds to complete..."
    wait $PID_AMD64
    wait $PID_ARM64

    # Create multi-arch manifests per registry (no cross-registry blob copies)
    echo -e "${BLUE}Creating multi-arch manifests...${NC}"

    if [ "$PUSH_GHCR" = true ]; then
        echo -e "${BLUE}  Creating GHCR manifest...${NC}"
        docker buildx imagetools create \
            -t "${GHCR_IMAGE}:${VERSION}" \
            "${GHCR_IMAGE}:${VERSION}-amd64" \
            "${GHCR_IMAGE}:${VERSION}-arm64"
    fi
    if [ "$PUSH_DOCKERHUB" = true ]; then
        echo -e "${BLUE}  Creating Docker Hub manifest...${NC}"
        docker buildx imagetools create \
            -t "${DOCKERHUB_IMAGE}:${VERSION}" \
            "${DOCKERHUB_IMAGE}:${VERSION}-amd64" \
            "${DOCKERHUB_IMAGE}:${VERSION}-arm64"
    fi
else
    # Sequential build (default): Build both platforms in one command
    echo -e "${YELLOW}Building sequentially with ${CPU_COUNT} cores (no cache)...${NC}"
    DOCKER_BUILDKIT=1 docker buildx build \
        --platform "$PLATFORMS" \
        ${BUILD_ARGS} \
        $TAGS \
        --push \
        .
fi

# ============================================================
# Step 6: Create GitHub release
# ============================================================
if [ "$SKIP_RELEASE" = true ]; then
    echo -e "${YELLOW}[6/7] Skipping GitHub release (--skip-release)${NC}"
else
    echo -e "${BLUE}[6/7] Creating GitHub release...${NC}"

    # Extract release notes from CHANGELOG: content between ## [<version>] and the next ## [
    CHANGELOG_NOTES=$(sed -n "/^## \[${VERSION}\]/,/^## \[/{/^## \[/!p}" "$CHANGELOG_FILE" | sed '/^$/d; 1{/^$/d}')

    if [ -z "$CHANGELOG_NOTES" ]; then
        echo -e "${YELLOW}  Warning: No changelog notes found for ${VERSION}${NC}"
        CHANGELOG_NOTES="No changelog notes available for this release."
    fi

    # Build pull commands for the release body
    PULL_COMMANDS=""
    if [ "$PUSH_GHCR" = true ]; then
        PULL_COMMANDS="docker pull ghcr.io/maziggy/bambuddy:${VERSION}"
    fi
    if [ "$PUSH_DOCKERHUB" = true ]; then
        if [ -n "$PULL_COMMANDS" ]; then
            PULL_COMMANDS="${PULL_COMMANDS}
# or
docker pull maziggy/bambuddy:${VERSION}"
        else
            PULL_COMMANDS="docker pull maziggy/bambuddy:${VERSION}"
        fi
    fi

    # Create the release body
    RELEASE_BODY=$(cat <<EOF
> [!NOTE]
> This is a **daily beta build**. It contains the latest fixes and improvements but may have undiscovered issues.
>
> **Docker users:** Update by pulling the new image:
> \`\`\`
> ${PULL_COMMANDS}
> \`\`\`
>
> **To receive beta update notifications in Bambuddy:** Enable *"Include beta versions"* in Settings → Updates.

---

${CHANGELOG_NOTES}
EOF
    )

    # Push the tag to remote
    echo "  Pushing tag v${VERSION} to remote..."
    git push origin "v${VERSION}"

    # Push the commit to remote
    CURRENT_BRANCH=$(git branch --show-current)
    echo "  Pushing ${CURRENT_BRANCH} to remote..."
    git push origin "${CURRENT_BRANCH}"

    # Create GitHub release
    gh release create "v${VERSION}" \
        --title "Daily Beta Build v${VERSION}" \
        --prerelease \
        --notes "$RELEASE_BODY"

    echo -e "${GREEN}  Created GitHub release: v${VERSION}${NC}"
fi

# ============================================================
# Step 7: Verify
# ============================================================
echo -e "${BLUE}[7/7] Verifying...${NC}"

if [ "$PUSH_GHCR" = true ]; then
    echo -e "${BLUE}GHCR manifest:${NC}"
    docker buildx imagetools inspect "${GHCR_IMAGE}:${VERSION}"
fi
if [ "$PUSH_DOCKERHUB" = true ]; then
    echo -e "${BLUE}Docker Hub manifest:${NC}"
    docker buildx imagetools inspect "${DOCKERHUB_IMAGE}:${VERSION}"
fi

if [ "$SKIP_RELEASE" != true ]; then
    echo ""
    echo -e "${BLUE}GitHub release:${NC}"
    gh release view "v${VERSION}"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Daily beta build complete!${NC}"
echo -e "${GREEN}  Version: ${VERSION}${NC}"
echo -e "${GREEN}================================================${NC}"
if [ "$PUSH_GHCR" = true ]; then
    echo "  GHCR:       ${GHCR_IMAGE}:${VERSION}"
fi
if [ "$PUSH_DOCKERHUB" = true ]; then
    echo "  Docker Hub: ${DOCKERHUB_IMAGE}:${VERSION}"
fi
if [ "$SKIP_RELEASE" != true ]; then
    echo "  Release:    https://github.com/${IMAGE_NAME}/releases/tag/v${VERSION}"
fi
echo ""
echo -e "${BLUE}Supported platforms:${NC}"
echo "  - linux/amd64 (Intel/AMD servers, desktops)"
echo "  - linux/arm64 (Raspberry Pi 4/5, Apple Silicon)"
echo ""
echo -e "${GREEN}Users can now run:${NC}"
if [ "$PUSH_GHCR" = true ]; then
    echo "  docker pull ${GHCR_IMAGE}:${VERSION}"
fi
if [ "$PUSH_DOCKERHUB" = true ]; then
    echo "  docker pull ${DOCKERHUB_IMAGE}:${VERSION}"
    echo "  docker pull ${IMAGE_NAME}:${VERSION}  # shorthand"
fi
