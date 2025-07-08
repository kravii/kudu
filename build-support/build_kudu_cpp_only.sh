#!/bin/bash
################################################################################
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
################################################################################
#
# Minimal Kudu C++ build script - builds only C++ binaries
# No Java, no tests, creates native-toolchain style package
#
################################################################################

set -e

# Configuration
SOURCE_ROOT=$(cd $(dirname $0)/..; pwd)
VERSION=$(cat $SOURCE_ROOT/version.txt)
BUILD_ROOT=${BUILD_ROOT:-$SOURCE_ROOT/build}
PACKAGE_NAME=${PACKAGE_NAME:-kudu-$VERSION}
PACKAGE_DIR=$BUILD_ROOT/package/$PACKAGE_NAME
NUM_PROCS=$(getconf _NPROCESSORS_ONLN)
THIRDPARTY_DIR=${THIRDPARTY_DIR:-$SOURCE_ROOT/thirdparty}

# Options
BUILD_DEBUG=${BUILD_DEBUG:-1}
BUILD_RELEASE=${BUILD_RELEASE:-1}

echo "Building Kudu C++ package: $PACKAGE_NAME"
echo "Build root: $BUILD_ROOT"
echo "Package directory: $PACKAGE_DIR"

# Clean up any existing package directory
if [ -d "$PACKAGE_DIR" ]; then
    echo "Removing existing package directory..."
    rm -rf "$PACKAGE_DIR"
fi
mkdir -p "$PACKAGE_DIR"

# Function to build Kudu C++ only
build_kudu_cpp() {
    local BUILD_TYPE=$1
    local BUILD_DIR=$BUILD_ROOT/$(echo $BUILD_TYPE | tr '[:upper:]' '[:lower:]')
    local INSTALL_DIR=$PACKAGE_DIR/$(echo $BUILD_TYPE | tr '[:upper:]' '[:lower:]')
    
    echo ""
    echo "=========================================="
    echo "Building Kudu C++ in $BUILD_TYPE mode..."
    echo "=========================================="
    
    # Create build directory
    mkdir -p $BUILD_DIR
    cd $BUILD_DIR
    
    # Clean any existing CMake cache
    rm -rf CMakeCache.txt CMakeFiles
    
    # Configure - NO TESTS!
    echo "Configuring $BUILD_TYPE build (no tests)..."
    if [ -d "$THIRDPARTY_DIR/installed/common/bin" ]; then
        CMAKE_CMD="$THIRDPARTY_DIR/installed/common/bin/cmake"
    else
        CMAKE_CMD="cmake"
    fi
    
    $CMAKE_CMD $SOURCE_ROOT \
        -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DKUDU_LINK=dynamic \
        -DNO_TESTS=1
    
    # Build only the main binaries
    echo "Building $BUILD_TYPE binaries..."
    make -j$NUM_PROCS kudu kudu-master kudu-tserver
    
    # Install manually (faster than make install)
    echo "Installing $BUILD_TYPE build..."
    mkdir -p $INSTALL_DIR/{bin,lib}
    
    # Copy binaries
    cp -v bin/kudu bin/kudu-master bin/kudu-tserver $INSTALL_DIR/bin/
    
    # Copy libraries
    find . -name "*.so*" -type f | grep -v test | while read lib; do
        cp -v "$lib" $INSTALL_DIR/lib/ 2>/dev/null || true
    done
    
    # Strip binaries for release builds
    if [ "$BUILD_TYPE" = "RELEASE" ]; then
        echo "Stripping release binaries..."
        strip $INSTALL_DIR/bin/* 2>/dev/null || true
        find $INSTALL_DIR/lib -name "*.so*" -exec strip {} \; 2>/dev/null || true
    fi
}

# Build release version
if [ "$BUILD_RELEASE" = "1" ]; then
    build_kudu_cpp "RELEASE"
else
    echo "Skipping release build"
fi

# Build debug version
if [ "$BUILD_DEBUG" = "1" ]; then
    build_kudu_cpp "DEBUG"
else
    echo "Skipping debug build"
fi

# Create toolchain-build-hash.txt
cd $SOURCE_ROOT
GIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
echo "$GIT_HASH" > $PACKAGE_DIR/toolchain-build-hash.txt

# Copy license and notice files
cp $SOURCE_ROOT/LICENSE.txt $PACKAGE_DIR/
cp $SOURCE_ROOT/NOTICE.txt $PACKAGE_DIR/

# Create README
cat > $PACKAGE_DIR/README.txt << EOF
Apache Kudu $VERSION C++ Package

This package contains C++ binaries only:
$(if [ "$BUILD_RELEASE" = "1" ]; then echo "- release/  : Release build of Kudu binaries and libraries"; fi)
$(if [ "$BUILD_DEBUG" = "1" ]; then echo "- debug/    : Debug build of Kudu binaries and libraries"; fi)
- toolchain-build-hash.txt : Git commit hash used for this build

Built on: $(date)
Host: $(hostname)

To use Java client, build separately with:
  cd java && ./gradlew assemble -x test
EOF

# Create the tarball
echo ""
echo "Creating tarball..."
cd $BUILD_ROOT/package
tar czf $PACKAGE_NAME.tar.gz $PACKAGE_NAME/

# Print summary
echo ""
echo "================================================================================"
echo "C++ Build complete!"
echo "Package created: $BUILD_ROOT/package/$PACKAGE_NAME.tar.gz"
echo ""
echo "Package contents:"
cd $PACKAGE_DIR
find . -type d | head -20 | sort | sed 's/^/  /'
echo ""
echo "Package size: $(du -h $BUILD_ROOT/package/$PACKAGE_NAME.tar.gz | cut -f1)"
echo ""
echo "To build only release: BUILD_DEBUG=0 $0"
echo "To build only debug: BUILD_RELEASE=0 $0"
echo "================================================================================"