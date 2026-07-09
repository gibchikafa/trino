#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [options]

Builds the Trino Docker image using the same inputs as Jenkinsfile.

Options:
  --arch <arch>              Target image architecture. Default: amd64
  --image-name <name>        Image name. Default: value from build-manifest.json
  --registry <registry>      Optional registry prefix, for example registry.example.com
  --tag-version <tag>        Full image tag version. Default: <project.version>-<version file>
  --server-artifact <name>   Server artifact id. Default: trino-server
  --work-dir <path>          Docker source directory. Default: core/docker
  --skip-maven-build         Reuse existing Maven artifacts from target directories
  --use-current-java         Use the current JAVA_HOME/PATH Java instead of downloading Temurin
  --push                    Push the image after building
  --no-push                 Do not push the image after building. Default
  -h, --help                Show this help

Environment overrides:
  ARCH, IMAGE_NAME, DOCKER_REGISTRY, TAG_VERSION, SERVER_ARTIFACT, WORK_DIR,
  TRINO_VERSION, JDK_RELEASE, JDK_DOWNLOAD_LINK, BUILD_JDK_DOWNLOAD_LINK,
  PUSH, SKIP_MAVEN_BUILD, USE_CURRENT_JAVA, DOCKER_USERNAME, DOCKER_PASSWORD
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_value() {
    local option=$1
    local value=${2-}
    [[ -n "${value}" ]] || die "${option} requires a value"
}

require_command() {
    local command_name=$1
    command -v "${command_name}" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
}

download_file() {
    local url=$1
    local output=$2

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 8 "${url}" -o "${output}"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${output}" "${url}"
    else
        die "Required command not found: curl or wget"
    fi
}

adoptium_arch_for_image_arch() {
    case "$1" in
        amd64) echo "x64" ;;
        arm64) echo "aarch64" ;;
        ppc64le) echo "ppc64le" ;;
        *) die "Unsupported architecture: $1" ;;
    esac
}

adoptium_arch_for_host() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "x64" ;;
        arm64 | aarch64) echo "aarch64" ;;
        ppc64le) echo "ppc64le" ;;
        *) die "Unsupported host architecture: $(uname -m)" ;;
    esac
}

adoptium_os_for_host() {
    case "$(uname -s)" in
        Linux) echo "linux" ;;
        Darwin) echo "mac" ;;
        *) die "Unsupported host OS: $(uname -s)" ;;
    esac
}

maven_eval() {
    local expression=$1
    "${ROOT_DIR}/mvnw" -f "${ROOT_DIR}/pom.xml" --quiet help:evaluate \
        -Dexpression="${expression}" \
        -DforceStdout \
        --raw-streams
}

resolve_java_home() {
    local extracted_jdk=$1

    if [[ -x "${extracted_jdk}/bin/java" ]]; then
        echo "${extracted_jdk}"
    elif [[ -x "${extracted_jdk}/Contents/Home/bin/java" ]]; then
        echo "${extracted_jdk}/Contents/Home"
    else
        die "Downloaded JDK did not contain a runnable java binary"
    fi
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

BUILD_TOOLS_DIR=""
CONTEXT_DIR=""
cleanup() {
    if [[ -n "${BUILD_TOOLS_DIR}" ]]; then
        rm -rf "${BUILD_TOOLS_DIR}"
    fi
    if [[ -n "${CONTEXT_DIR}" ]]; then
        rm -rf "${CONTEXT_DIR}"
    fi
}
trap cleanup EXIT

ARCH="${ARCH:-amd64}"
IMAGE_NAME="${IMAGE_NAME:-}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-}"
TAG_VERSION="${TAG_VERSION:-}"
SERVER_ARTIFACT="${SERVER_ARTIFACT:-trino-server}"
WORK_DIR="${WORK_DIR:-core/docker}"
TRINO_VERSION="${TRINO_VERSION:-}"
JDK_RELEASE="${JDK_RELEASE:-}"
JDK_DOWNLOAD_LINK="${JDK_DOWNLOAD_LINK:-}"
BUILD_JDK_DOWNLOAD_LINK="${BUILD_JDK_DOWNLOAD_LINK:-}"
PUSH="${PUSH:-false}"
SKIP_MAVEN_BUILD="${SKIP_MAVEN_BUILD:-false}"
USE_CURRENT_JAVA="${USE_CURRENT_JAVA:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            need_value "$1" "${2-}"
            ARCH=$2
            shift 2
            ;;
        --image-name)
            need_value "$1" "${2-}"
            IMAGE_NAME=$2
            shift 2
            ;;
        --registry)
            need_value "$1" "${2-}"
            DOCKER_REGISTRY=$2
            shift 2
            ;;
        --tag-version)
            need_value "$1" "${2-}"
            TAG_VERSION=$2
            shift 2
            ;;
        --server-artifact)
            need_value "$1" "${2-}"
            SERVER_ARTIFACT=$2
            shift 2
            ;;
        --work-dir)
            need_value "$1" "${2-}"
            WORK_DIR=$2
            shift 2
            ;;
        --skip-maven-build)
            SKIP_MAVEN_BUILD=true
            shift
            ;;
        --use-current-java)
            USE_CURRENT_JAVA=true
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --no-push)
            PUSH=false
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

case "${ARCH}" in
    amd64 | arm64 | ppc64le) ;;
    *) die "Unsupported architecture: ${ARCH}" ;;
esac

require_command jq
require_command tar
require_command docker

[[ -f "${ROOT_DIR}/mvnw" ]] || die "mvnw not found"
chmod +x "${ROOT_DIR}/mvnw"

BUILD_MANIFEST="${ROOT_DIR}/build-manifest.json"
[[ -f "${BUILD_MANIFEST}" ]] || die "build-manifest.json not found"

if [[ -z "${IMAGE_NAME}" ]]; then
    IMAGE_NAME="$(jq -r '.[0].name' "${BUILD_MANIFEST}")"
fi

DOCKERFILE_FROM_MANIFEST="$(jq -r '.[0].dockerFile' "${BUILD_MANIFEST}")"
DOCKER_SOURCE_DIR="${ROOT_DIR}/${WORK_DIR}"
DOCKERFILE_SOURCE="${ROOT_DIR}/${DOCKERFILE_FROM_MANIFEST}"
[[ -d "${DOCKER_SOURCE_DIR}" ]] || die "Docker source directory not found: ${DOCKER_SOURCE_DIR}"
[[ -f "${DOCKERFILE_SOURCE}" ]] || die "Dockerfile not found: ${DOCKERFILE_SOURCE}"

if [[ -z "${TRINO_VERSION}" ]]; then
    TRINO_VERSION="$(maven_eval project.version)"
fi

if [[ -z "${JDK_RELEASE}" ]]; then
    JDK_RELEASE="$(maven_eval temurin.release)"
fi

if [[ -z "${JDK_DOWNLOAD_LINK}" ]]; then
    JDK_DOWNLOAD_LINK="https://api.adoptium.net/v3/binary/version/${JDK_RELEASE}/linux/$(adoptium_arch_for_image_arch "${ARCH}")/jdk/hotspot/normal/eclipse?project=jdk"
fi

if [[ -z "${BUILD_JDK_DOWNLOAD_LINK}" ]]; then
    BUILD_JDK_DOWNLOAD_LINK="https://api.adoptium.net/v3/binary/version/${JDK_RELEASE}/$(adoptium_os_for_host)/$(adoptium_arch_for_host)/jdk/hotspot/normal/eclipse?project=jdk"
fi

if [[ -z "${TAG_VERSION}" ]]; then
    VERSION_SUFFIX="$(tr -d '[:space:]' < "${ROOT_DIR}/version")"
    TAG_VERSION="${TRINO_VERSION}-${VERSION_SUFFIX}"
fi

echo "TRINO_VERSION=${TRINO_VERSION}"
echo "JDK_RELEASE=${JDK_RELEASE}"
echo "JDK_DOWNLOAD_LINK=${JDK_DOWNLOAD_LINK}"
echo "ARCH=${ARCH}"
echo "TAG_VERSION=${TAG_VERSION}"

if [[ "${SKIP_MAVEN_BUILD}" != "true" ]]; then
    if [[ "${USE_CURRENT_JAVA}" == "true" ]]; then
        echo "Building Maven artifacts with current Java"
        "${ROOT_DIR}/mvnw" clean package -DskipTests
    else
        echo "Downloading build JDK from ${BUILD_JDK_DOWNLOAD_LINK}"
        BUILD_TOOLS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trino-build-tools.XXXXXX")"
        JDK_DIR="${BUILD_TOOLS_DIR}/jdk"
        mkdir -p "${JDK_DIR}"
        JDK_ARCHIVE="${BUILD_TOOLS_DIR}/jdk.tar.gz"
        download_file "${BUILD_JDK_DOWNLOAD_LINK}" "${JDK_ARCHIVE}"
        tar -xzf "${JDK_ARCHIVE}" -C "${JDK_DIR}" --strip-components=1
        rm -f "${JDK_ARCHIVE}"
        BUILD_JAVA_HOME="$(resolve_java_home "${JDK_DIR}")"

        echo "Building Maven artifacts with JAVA_HOME=${BUILD_JAVA_HOME}"
        JAVA_HOME="${BUILD_JAVA_HOME}" "${ROOT_DIR}/mvnw" clean package -DskipTests
    fi
else
    echo "Skipping Maven build; using existing artifacts"
fi

SERVER_TAR="${ROOT_DIR}/core/${SERVER_ARTIFACT}/target/${SERVER_ARTIFACT}-${TRINO_VERSION}.tar.gz"
CLI_JAR="${ROOT_DIR}/client/trino-cli/target/trino-cli-${TRINO_VERSION}-executable.jar"
[[ -f "${SERVER_TAR}" ]] || die "Server artifact not found: ${SERVER_TAR}"
[[ -f "${CLI_JAR}" ]] || die "CLI artifact not found: ${CLI_JAR}"

CONTEXT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trino-image.XXXXXX")"

echo "Preparing Docker build context in ${CONTEXT_DIR}"
cp -R "${DOCKER_SOURCE_DIR}/." "${CONTEXT_DIR}/"
cp -f "${SERVER_TAR}" "${CONTEXT_DIR}/"
cp -f "${CLI_JAR}" "${CONTEXT_DIR}/trino-cli.jar"
tar -C "${CONTEXT_DIR}" -xzf "${CONTEXT_DIR}/${SERVER_ARTIFACT}-${TRINO_VERSION}.tar.gz"
rm -f "${CONTEXT_DIR}/${SERVER_ARTIFACT}-${TRINO_VERSION}.tar.gz"
rm -rf "${CONTEXT_DIR}/trino-server"
mv "${CONTEXT_DIR}/${SERVER_ARTIFACT}-${TRINO_VERSION}" "${CONTEXT_DIR}/trino-server"
cp -R "${DOCKER_SOURCE_DIR}/bin" "${CONTEXT_DIR}/trino-server"

IMAGE_REF="${IMAGE_NAME}:${TAG_VERSION}"
if [[ -n "${DOCKER_REGISTRY}" ]]; then
    IMAGE_REF="${DOCKER_REGISTRY%/}/${IMAGE_REF}"
fi

echo "Building Docker image ${IMAGE_REF}"
docker build \
    "${CONTEXT_DIR}" \
    --progress=plain \
    --pull \
    --platform "linux/${ARCH}" \
    --build-arg "ARCH=${ARCH}" \
    --build-arg "JDK_VERSION=${JDK_RELEASE}" \
    --build-arg "JDK_DOWNLOAD_LINK=${JDK_DOWNLOAD_LINK}" \
    -f "${CONTEXT_DIR}/$(basename "${DOCKERFILE_SOURCE}")" \
    -t "${IMAGE_REF}"

if [[ "${PUSH}" == "true" ]]; then
    if [[ -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
        echo "Logging in to Docker registry"
        if [[ -n "${DOCKER_REGISTRY}" ]]; then
            printf '%s' "${DOCKER_PASSWORD}" | docker login "${DOCKER_REGISTRY}" -u "${DOCKER_USERNAME}" --password-stdin
        else
            printf '%s' "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
        fi
    fi

    echo "Pushing Docker image ${IMAGE_REF}"
    docker push "${IMAGE_REF}"
else
    echo "Skipping push. Re-run with --push or PUSH=true to push ${IMAGE_REF}"
fi
