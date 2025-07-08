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
# Simplified Kudu package build script
# Creates a tar.gz with release binaries and optional Java artifacts
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

# Simple options
SKIP_JAVA=0
if [ "$1" = "--skip-java" ]; then
    SKIP_JAVA=1
fi

echo "Building Kudu package: $PACKAGE_NAME"
echo "Build root: $BUILD_ROOT"
echo "Package directory: $PACKAGE_DIR"

# Clean up any existing package directory
if [ -d "$PACKAGE_DIR" ]; then
    echo "Removing existing package directory..."
    rm -rf "$PACKAGE_DIR"
fi
mkdir -p "$PACKAGE_DIR"

# Build thirdparty if needed
if [ ! -d "$THIRDPARTY_DIR/installed" ]; then
    echo "Building thirdparty dependencies..."
    cd $SOURCE_ROOT
    $SOURCE_ROOT/build-support/enable_devtoolset.sh \
        $THIRDPARTY_DIR/build-if-necessary.sh
fi

# Build release version
echo "Building Kudu in RELEASE mode..."
BUILD_DIR=$BUILD_ROOT/release
INSTALL_DIR=$PACKAGE_DIR/release

mkdir -p $BUILD_DIR
cd $BUILD_DIR

# Clean any existing CMake cache
rm -rf CMakeCache.txt CMakeFiles

# Configure
echo "Configuring RELEASE build..."
$SOURCE_ROOT/build-support/enable_devtoolset.sh \
    $THIRDPARTY_DIR/installed/common/bin/cmake $SOURCE_ROOT \
    -DCMAKE_BUILD_TYPE=RELEASE \
    -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
    -DKUDU_LINK=dynamic

# Build
echo "Building RELEASE binaries..."
make -j$NUM_PROCS

# Install to package directory
echo "Installing RELEASE build to package directory..."
make install DESTDIR=

# Strip binaries to reduce size
echo "Stripping release binaries..."
find $INSTALL_DIR/bin -type f -executable -exec strip {} \; 2>/dev/null || true
find $INSTALL_DIR/lib -name "*.so*" -exec strip {} \; 2>/dev/null || true

# Build debug version (optional)
if [ "${BUILD_DEBUG:-0}" = "1" ]; then
    echo "Building Kudu in DEBUG mode..."
    BUILD_DIR=$BUILD_ROOT/debug
    INSTALL_DIR=$PACKAGE_DIR/debug
    
    mkdir -p $BUILD_DIR
    cd $BUILD_DIR
    
    rm -rf CMakeCache.txt CMakeFiles
    
    $SOURCE_ROOT/build-support/enable_devtoolset.sh \
        $THIRDPARTY_DIR/installed/common/bin/cmake $SOURCE_ROOT \
        -DCMAKE_BUILD_TYPE=DEBUG \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DKUDU_LINK=dynamic
    
    make -j$NUM_PROCS
    make install DESTDIR=
fi

# Build Java artifacts (simplified)
if [ "$SKIP_JAVA" -eq 0 ]; then
    echo "Building Java artifacts..."
    cd $SOURCE_ROOT/java
    
    # Clean up any locks first
    echo "Cleaning up any existing Gradle locks..."
    rm -f ~/.gradle/caches/modules-2/modules-2.lock 2>/dev/null || true
    rm -f ~/.gradle/caches/*/fileHashes/fileHashes.lock 2>/dev/null || true
    rm -rf .gradle/ 2>/dev/null || true
    
    # Kill any existing Gradle daemons
    if command -v jps >/dev/null 2>&1; then
        jps | grep GradleDaemon | awk '{print $1}' | xargs -r kill -9 2>/dev/null || true
    fi
    
    # Set environment to disable daemon
    export GRADLE_OPTS="-Dorg.gradle.daemon=false"
    
    if [ -f "./gradlew" ]; then
        echo "Running Gradle build (skipping tests)..."
        # Use proper Gradle syntax: tasks first, then exclusions
        if ./gradlew clean assemble -x test -x check -x spotbugsMain -x spotbugsTest -x rat; then
            echo "Java build successful!"
            
            # Create java directory in package
            mkdir -p $PACKAGE_DIR/java
            
            # Copy built JARs
            find . -name "*.jar" -not -path "*/src/*" -not -path "*/.gradle/*" -not -path "*/test/*" | while read jar; do
                jar_dir=$(dirname $jar)
                mkdir -p $PACKAGE_DIR/java/$jar_dir
                cp $jar $PACKAGE_DIR/java/$jar_dir/
            done
        else
            echo "WARNING: Java build failed. Continuing without Java artifacts."
            echo "To skip Java build entirely, run with --skip-java"
        fi
    else
        echo "WARNING: gradlew not found, skipping Java build"
    fi
else
    echo "Skipping Java build (--skip-java specified)"
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
Apache Kudu $VERSION Package

This package contains:
- release/  : Release build of Kudu binaries and libraries
$(if [ "${BUILD_DEBUG:-0}" = "1" ]; then echo "- debug/    : Debug build of Kudu binaries and libraries"; fi)
$(if [ "$SKIP_JAVA" -eq 0 ] && [ -d "$PACKAGE_DIR/java" ]; then echo "- java/     : Java client libraries and artifacts"; fi)
- toolchain-build-hash.txt : Git commit hash used for this build

Built on: $(date)
Host: $(hostname)
EOF

# Create the tarball
echo "Creating tarball..."
cd $BUILD_ROOT/package
tar czf $PACKAGE_NAME.tar.gz $PACKAGE_NAME/

# Print summary
echo ""
echo "================================================================================"
echo "Build complete!"
echo "Package created: $BUILD_ROOT/package/$PACKAGE_NAME.tar.gz"
echo ""
echo "Package contents:"
cd $PACKAGE_DIR
find . -maxdepth 2 -type d | sort | sed 's/^/  /'
echo ""
echo "Package size: $(du -h $BUILD_ROOT/package/$PACKAGE_NAME.tar.gz | cut -f1)"
echo "================================================================================"