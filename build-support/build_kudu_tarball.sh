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
# Simple Kudu tarball build script
# Builds only C++ binaries and creates a minimal tar.gz package
#
################################################################################

set -e

# Configuration
SOURCE_ROOT=$(cd $(dirname $0)/..; pwd)
VERSION=$(cat $SOURCE_ROOT/version.txt)
BUILD_TYPE=${BUILD_TYPE:-RELEASE}
PACKAGE_NAME=${PACKAGE_NAME:-kudu-$VERSION-$BUILD_TYPE}
BUILD_DIR=$SOURCE_ROOT/build/$BUILD_TYPE
DIST_DIR=$SOURCE_ROOT/dist/$PACKAGE_NAME
NUM_PROCS=$(getconf _NPROCESSORS_ONLN)
THIRDPARTY_DIR=${THIRDPARTY_DIR:-$SOURCE_ROOT/thirdparty}

echo "============================================"
echo "Building Kudu $VERSION ($BUILD_TYPE)"
echo "Source: $SOURCE_ROOT"
echo "Build: $BUILD_DIR"
echo "Distribution: $DIST_DIR"
echo "============================================"

# Check if thirdparty is built
if [ ! -d "$THIRDPARTY_DIR/installed" ]; then
    echo ""
    echo "ERROR: Thirdparty dependencies not found at $THIRDPARTY_DIR/installed"
    echo ""
    echo "Please build thirdparty first by running:"
    echo "  cd $THIRDPARTY_DIR"
    echo "  ./build-if-necessary.sh"
    echo ""
    echo "Note: You may need to install build tools first:"
    echo "  sudo apt-get install autoconf automake libtool pkg-config"
    echo ""
    exit 1
fi

# Create build directory
mkdir -p $BUILD_DIR
cd $BUILD_DIR

# Configure if needed
if [ ! -f "CMakeCache.txt" ]; then
    echo "Configuring build..."
    $THIRDPARTY_DIR/installed/common/bin/cmake $SOURCE_ROOT \
        -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
        -DKUDU_LINK=dynamic \
        -DNO_TESTS=1
fi

# Build
echo "Building Kudu..."
make -j$NUM_PROCS kudu kudu-master kudu-tserver

# Create distribution directory
echo "Creating distribution..."
rm -rf $DIST_DIR
mkdir -p $DIST_DIR/{bin,lib,include,share}

# Copy binaries
echo "Copying binaries..."
cp -v bin/kudu bin/kudu-master bin/kudu-tserver $DIST_DIR/bin/

# Copy libraries
echo "Copying libraries..."
find lib* -name "*.so*" -type f -exec cp -v {} $DIST_DIR/lib/ \; 2>/dev/null || true

# Copy headers (optional, can be skipped for smaller package)
if [ "${INCLUDE_HEADERS:-0}" = "1" ]; then
    echo "Copying headers..."
    find src -name "*.h" -type f | while read header; do
        dest_dir=$DIST_DIR/include/$(dirname $header)
        mkdir -p "$dest_dir"
        cp "$header" "$dest_dir/"
    done
fi

# Strip binaries for smaller size
if [ "$BUILD_TYPE" = "RELEASE" ]; then
    echo "Stripping binaries..."
    strip $DIST_DIR/bin/* 2>/dev/null || true
    find $DIST_DIR/lib -name "*.so*" -exec strip {} \; 2>/dev/null || true
fi

# Add metadata files
cd $SOURCE_ROOT
echo "$VERSION" > $DIST_DIR/VERSION
git rev-parse HEAD > $DIST_DIR/GIT_HASH 2>/dev/null || echo "unknown" > $DIST_DIR/GIT_HASH
cp LICENSE.txt NOTICE.txt $DIST_DIR/

# Create README
cat > $DIST_DIR/README.txt << EOF
Apache Kudu $VERSION - $BUILD_TYPE Build

This package contains Kudu binaries built from source.

Contents:
- bin/         : Kudu executables (kudu, kudu-master, kudu-tserver)
- lib/         : Shared libraries
$(if [ "${INCLUDE_HEADERS:-0}" = "1" ]; then echo "- include/     : Header files"; fi)
- VERSION      : Version information
- GIT_HASH     : Git commit used for this build
- LICENSE.txt  : Apache license
- NOTICE.txt   : Copyright notices

To run Kudu:
1. Set LD_LIBRARY_PATH to include the lib directory
2. Run the binaries from the bin directory

Built on: $(date)
Host: $(hostname)
Build type: $BUILD_TYPE
EOF

# Create tarball
echo "Creating tarball..."
cd $(dirname $DIST_DIR)
tar czf $PACKAGE_NAME.tar.gz $PACKAGE_NAME/

# Summary
echo ""
echo "============================================"
echo "Build complete!"
echo "Package: $(pwd)/$PACKAGE_NAME.tar.gz"
echo "Size: $(du -h $PACKAGE_NAME.tar.gz | cut -f1)"
echo ""
echo "Contents:"
tar tzf $PACKAGE_NAME.tar.gz | head -20
echo "..."
echo "Total files: $(tar tzf $PACKAGE_NAME.tar.gz | wc -l)"
echo "============================================"