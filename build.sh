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

ARCH="$(uname -m)"

DOCKER_REPOSITORY_URL="https://github.com/zambon/moby.git"
DOCKER_REPOSITORY_PATH="$PWD/build/docker"

BUILD_IMAGE="docker-build:v$DOCKER_VERSION"
BUILD_CONTAINER="docker-build-v$DOCKER_VERSION"

ARTIFACT_NAME="docker-$DOCKER_VERSION-$ARCH.tgz"
BUILD_TARGET="$(git rev-parse --show-toplevel)/build"

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
  # Prepare build image.
  docker build -t $BUILD_IMAGE -f Dockerfile.$ARCH .

  docker run \
    --name $BUILD_CONTAINER \
    --privileged -dt \
    -e DOCKER_VERSION \
    $BUILD_IMAGE /bin/bash -exc '
ARCH="$(uname -m)"
PACKAGE_ROOT=$(mktemp -d)
mkdir /build

# Build Docker.
hack/make.sh binary

# Move artifacts for packaging.
mkdir $PACKAGE_ROOT/docker
if [ -d bundles/$DOCKER_VERSION/binary ]; then
  cp -vL bundles/$DOCKER_VERSION/binary/* $PACKAGE_ROOT/docker
else
  cp -vL bundles/$DOCKER_VERSION/binary-{client,daemon}/* $PACKAGE_ROOT/docker
fi

# Remove symlinks and checksums.
rm -vf $PACKAGE_ROOT/docker/*{.{sha256,md5},-$DOCKER_VERSION}

# Package.
ARTIFACT_NAME="docker-$DOCKER_VERSION-$ARCH.tgz"
pushd $PACKAGE_ROOT
tar -zcvf $ARTIFACT_NAME docker/*
popd

cp -v $PACKAGE_ROOT/$ARTIFACT_NAME /build
rm -rf $PACKAGE_ROOT
'
  docker logs -f $BUILD_CONTAINER
  docker wait $BUILD_CONTAINER > /dev/null
  docker cp $BUILD_CONTAINER:/build/$ARTIFACT_NAME $BUILD_TARGET/$ARTIFACT_NAME
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
