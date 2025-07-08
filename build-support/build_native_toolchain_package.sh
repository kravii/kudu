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
# Build Kudu package with native-toolchain structure
# Creates: debug/, release/, java/, toolchain-build-hash.txt
#
################################################################################

set -e
set -o pipefail

# Get the absolute path to the source root
SOURCE_ROOT=$(cd $(dirname $0)/..; pwd)
cd $SOURCE_ROOT

# Read version from version.txt
VERSION=$(cat version.txt)
PACKAGE_NAME="kudu-$VERSION"
PACKAGE_DIR="$SOURCE_ROOT/build/package/$PACKAGE_NAME"

echo "================================================================================"
echo "Building Kudu native-toolchain package"
echo "Version: $VERSION"
echo "================================================================================"

# Create package directory structure
echo "Creating package directory structure..."
rm -rf $PACKAGE_DIR
mkdir -p $PACKAGE_DIR/{debug,release,java}

# Function to build C++ binaries
build_cpp() {
    local BUILD_TYPE=$1
    local INSTALL_DIR=$2
    
    echo ""
    echo "Building $BUILD_TYPE binaries..."
    
    local BUILD_DIR="$SOURCE_ROOT/build/$BUILD_TYPE"
    mkdir -p $BUILD_DIR
    cd $BUILD_DIR
    
    # Configure with CMake - set install prefix to root
    cmake \
        -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
        -DCMAKE_INSTALL_PREFIX=/ \
        -DKUDU_USE_LTO=OFF \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        $SOURCE_ROOT
    
    # Build
    make -j$(nproc)
    
    # Install with DESTDIR to get files in the right place
    make install DESTDIR=$INSTALL_DIR
    
    # The above creates nested directories, so we need to move files up
    if [ -d "$INSTALL_DIR/usr/local" ]; then
        # Move files from usr/local/* to the root
        cp -r $INSTALL_DIR/usr/local/* $INSTALL_DIR/
        rm -rf $INSTALL_DIR/usr
    fi
    
    echo "$BUILD_TYPE build complete!"
}

# Check if thirdparty is built
if [ ! -d "$SOURCE_ROOT/thirdparty/installed" ]; then
    echo "Building thirdparty dependencies..."
    cd $SOURCE_ROOT
    ./thirdparty/build-if-necessary.sh
fi

# Build debug binaries
build_cpp "debug" "$PACKAGE_DIR/debug"

# Build release binaries  
build_cpp "release" "$PACKAGE_DIR/release"

# Build Java artifacts (skip problematic Scala modules)
echo ""
echo "Building Java artifacts..."
cd $SOURCE_ROOT/java

# Set up Gradle environment
export GRADLE_USER_HOME=${GRADLE_USER_HOME:-$HOME/.gradle}
export GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.parallel=false -Xmx2g"

# Clean Gradle environment
rm -rf .gradle 2>/dev/null || true

# Build only the core Java modules (skip backup modules that have Scala issues)
echo "Building Java JARs..."
./gradlew --gradle-user-home=$GRADLE_USER_HOME \
    :kudu-proto:jar \
    :kudu-client:jar \
    :kudu-client:shadowJar \
    :kudu-test-utils:jar \
    :kudu-subprocess:jar \
    :kudu-subprocess:shadowJar \
    :kudu-hive:jar \
    -x test -x check -x spotbugsMain -x spotbugsTest || {
    echo "WARNING: Some Java modules failed to build. Continuing with available JARs..."
}

# Also build source and javadoc JARs for core modules
./gradlew --gradle-user-home=$GRADLE_USER_HOME \
    :kudu-proto:sourcesJar \
    :kudu-client:sourcesJar \
    :kudu-test-utils:sourcesJar \
    :kudu-subprocess:sourcesJar \
    :kudu-hive:sourcesJar \
    :kudu-proto:javadocJar \
    :kudu-client:javadocJar \
    :kudu-test-utils:javadocJar \
    :kudu-subprocess:javadocJar \
    :kudu-hive:javadocJar \
    -x test -x check || {
    echo "WARNING: Some source/javadoc JARs failed to build. Continuing..."
}

# Copy Java artifacts
echo "Copying Java artifacts..."
find . -name "*.jar" -type f -not -path "*/src/*" -not -path "*/.gradle/*" -not -path "*/build/tmp/*" | while read jar; do
    if [ -s "$jar" ]; then
        cp -v "$jar" $PACKAGE_DIR/java/
    fi
done

# Create toolchain-build-hash.txt
echo "Creating toolchain-build-hash.txt..."
cd $SOURCE_ROOT
COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
echo "$COMMIT_HASH" > $PACKAGE_DIR/toolchain-build-hash.txt

# Add README
cat > $PACKAGE_DIR/README.txt << EOF
Apache Kudu $VERSION
Native Toolchain Package

This package contains:
- debug/    : Debug build binaries and libraries
- release/  : Release build binaries and libraries  
- java/     : Java client and utility JARs
- toolchain-build-hash.txt : Git commit hash

Built on: $(date)
EOF

# Create the tar.gz package
echo ""
echo "Creating tar.gz package..."
cd $SOURCE_ROOT/build/package
tar -czf "$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME"

# Summary
echo ""
echo "================================================================================"
echo "Build complete!"
echo ""
echo "Package created: $SOURCE_ROOT/build/package/$PACKAGE_NAME.tar.gz"
echo ""
echo "Contents:"
cd $PACKAGE_DIR
echo "  Debug binaries: $(find debug -name "kudu*" -type f | wc -l) files"
echo "  Release binaries: $(find release -name "kudu*" -type f | wc -l) files"
echo "  Java JARs: $(ls java/*.jar 2>/dev/null | wc -l) files"
echo ""
echo "Package size: $(du -h ../kudu-$VERSION.tar.gz | cut -f1)"
echo "================================================================================"