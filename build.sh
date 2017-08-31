#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
set -e

[ $# -ne 1 ] && \
  echo "Build Docker" && \
  echo "    Usage: ${0} <DOCKER_VERSION>" && \
  echo "  Example: ${0} 1.10.3" && \
  exit 1

DOCKER_VERSION="$(echo "$1" | sed -E 's/^v//')"
export DOCKER_VERSION

DOCKER_REPOSITORY_URL="https://github.com/zambon/moby.git"
DOCKER_REPOSITORY_PATH="$PWD/build/docker"

BUILD_IMAGE="docker-build:v$DOCKER_VERSION"
BUILD_CONTAINER="docker-build-v$DOCKER_VERSION"

BUILD_TARGET="$(git rev-parse --show-toplevel)/build"

get_arch()
{
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64)
      echo "amd64"
      ;;
    armv6l|armv7l)
      echo "armhf"
      ;;
    ppc64le|s390x)
      echo "$arch"
      ;;
    *)
      echo "Unsupported architecture '$arch'"
      exit 1
      ;;
  esac
}
export -f get_arch

# Check if Docker is installed and running.
check_docker()
{
  docker info > /dev/null 2>&1 || \
    (echo "Docker needs to be installed and running. Wait, wut?" && exit 1)
}

# Cleaning up after yourself is a good habit.
cleanup()
{
  docker rm -vf $BUILD_CONTAINER > /dev/null 2>&1 || true
}

# Clone/fetch Moby repo.
prepare_repo()
{
  if [ ! -d "$DOCKER_REPOSITORY_PATH" ]; then
    git clone $DOCKER_REPOSITORY_URL $DOCKER_REPOSITORY_PATH
    cd $DOCKER_REPOSITORY_PATH
  else
    cd $DOCKER_REPOSITORY_PATH
    git fetch origin
  fi

  # Some tags (e.g.: 'v1.12.1') require modifications to be able to build.
  # These modifications, when needed, were made in
  # zambon/moby@v$DOCKER_VERSION-build. If 'v$DOCKER_VERSION-build' branch
  # doesn't exist, use the 'v$DOCKER_VERSION' tag.
  BRANCHES="$(git branch -a)"
  if echo "$BRANCHES" | grep -q "v$DOCKER_VERSION-build"; then
    git reset --hard origin/v$DOCKER_VERSION-build
  else
    git reset --hard v$DOCKER_VERSION
  fi
}

# Down to business.
build()
{
  ARCH="$(get_arch)"
  export ARTIFACT_NAME="docker-$DOCKER_VERSION-$ARCH.tgz"

  # Prepare build image.
  if [ "$ARCH" = "amd64" ]; then
    docker build -t $BUILD_IMAGE -f Dockerfile .
  else
    docker build -t $BUILD_IMAGE -f Dockerfile.$ARCH .
  fi

  # Not proud.
  if [ "$ARCH" = "ppc64le" ] && [ "$DOCKER_VERSION" = "1.10.3" ]; then
    BUILD_COMMAND="gccgo"
  else
    BUILD_COMMAND="binary"
  fi
  export BUILD_COMMAND

  docker run \
    --name $BUILD_CONTAINER \
    --privileged -dt \
    -e DOCKER_VERSION \
    -e ARTIFACT_NAME \
    -e BUILD_COMMAND \
    $BUILD_IMAGE /bin/bash -exc '
PACKAGE_ROOT=$(mktemp -d)
mkdir /build

# Build Docker.
hack/make.sh $BUILD_COMMAND

if [ -d bundles/$DOCKER_VERSION/$BUILD_COMMAND ]; then
  PACKAGE_STRUCTURE=usr/local/bin
else
  PACKAGE_STRUCTURE=docker
fi
mkdir -p $PACKAGE_ROOT/$PACKAGE_STRUCTURE

# Move artifacts for packaging.
if [ -d bundles/$DOCKER_VERSION/$BUILD_COMMAND ]; then
  cp -vL \
    bundles/$DOCKER_VERSION/$BUILD_COMMAND/* \
    $PACKAGE_ROOT/$PACKAGE_STRUCTURE
else
  cp -vL \
    bundles/$DOCKER_VERSION/$BUILD_COMMAND-{client,daemon}/* \
    $PACKAGE_ROOT/$PACKAGE_STRUCTURE
fi

# Remove symlinks and checksums.
rm -vf $PACKAGE_ROOT/$PACKAGE_STRUCTURE/*{.{sha256,md5},-$DOCKER_VERSION}

# Package.
cd $PACKAGE_ROOT
tar -zcvf $ARTIFACT_NAME $PACKAGE_STRUCTURE/*
cp -v $ARTIFACT_NAME /build

cd /build
shasum -a 256 $ARTIFACT_NAME | cut -d " " -f 1 > $ARTIFACT_NAME.sha256
'
  docker logs -f $BUILD_CONTAINER
  docker wait $BUILD_CONTAINER > /dev/null
  docker cp $BUILD_CONTAINER:/build/$ARTIFACT_NAME $BUILD_TARGET/$ARTIFACT_NAME
  docker cp $BUILD_CONTAINER:/build/$ARTIFACT_NAME.sha256 $BUILD_TARGET/$ARTIFACT_NAME.sha256
  docker rm -v $BUILD_CONTAINER

  echo "Build image left behind:"
  docker images $BUILD_IMAGE
}

trap cleanup EXIT

check_docker
cleanup
prepare_repo
build
cleanup
