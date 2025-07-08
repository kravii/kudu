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
# Full Kudu package build - builds everything including all Java artifacts
# Creates native-toolchain style structure with all JARs
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

echo "Building Full Kudu package: $PACKAGE_NAME"
echo "Source: $SOURCE_ROOT"
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
    echo "ERROR: Thirdparty not built. Please build first with:"
    echo "  cd $THIRDPARTY_DIR && ./build-if-necessary.sh"
    exit 1
fi

# Function to build Kudu C++
build_kudu_cpp() {
    local BUILD_TYPE=$1
    local BUILD_DIR=$BUILD_ROOT/$(echo $BUILD_TYPE | tr '[:upper:]' '[:lower:]')
    local INSTALL_DIR=$PACKAGE_DIR/$(echo $BUILD_TYPE | tr '[:upper:]' '[:lower:]')
    
    echo ""
    echo "=========================================="
    echo "Building Kudu C++ in $BUILD_TYPE mode..."
    echo "=========================================="
    
    mkdir -p $BUILD_DIR
    cd $BUILD_DIR
    
    rm -rf CMakeCache.txt CMakeFiles
    
    # Configure with tests disabled
    $THIRDPARTY_DIR/installed/common/bin/cmake $SOURCE_ROOT \
        -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DKUDU_LINK=dynamic \
        -DNO_TESTS=1
    
    # Build
    echo "Building $BUILD_TYPE binaries..."
    make -j$NUM_PROCS
    
    # Install
    echo "Installing $BUILD_TYPE build..."
    make install DESTDIR=
    
    # Strip binaries for release
    if [ "$BUILD_TYPE" = "RELEASE" ]; then
        echo "Stripping release binaries..."
        find $INSTALL_DIR/bin -type f -executable -exec strip {} \; 2>/dev/null || true
        find $INSTALL_DIR/lib -name "*.so*" -exec strip {} \; 2>/dev/null || true
    fi
}

# Build release C++
build_kudu_cpp "RELEASE"

# Build debug C++
build_kudu_cpp "DEBUG"

# Build Java artifacts
echo ""
echo "=========================================="
echo "Building Java artifacts..."
echo "=========================================="
cd $SOURCE_ROOT/java

# Clean up Gradle locks
echo "Cleaning Gradle environment..."
rm -rf .gradle ~/.gradle/caches/modules-2/modules-2.lock 2>/dev/null || true
if command -v jps >/dev/null 2>&1; then
    jps | grep GradleDaemon | awk '{print $1}' | xargs -r kill -9 2>/dev/null || true
fi

# Ensure gradlew uses correct version
if [ -f "./gradlew" ]; then
    # Stop any existing daemons
    ./gradlew --stop 2>/dev/null || true
    
    # Set environment
    export GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.parallel=false -Xmx2g"
    
    echo "Building all Java artifacts (this may take a while)..."
    
    # Clean first
    ./gradlew clean || true
    
    # Build all artifacts step by step to ensure everything is built
    echo "Building main JARs..."
    ./gradlew jar -x test -x check || exit 1
    
    echo "Building shadow/fat JARs..."
    ./gradlew shadowJar -x test -x check || true
    
    echo "Building source JARs..."
    ./gradlew sourcesJar -x test -x check || exit 1
    
    echo "Building test JARs..."
    ./gradlew testJar -x test -x check || exit 1
    
    echo "Building test source JARs..."
    ./gradlew testSourcesJar -x test -x check || exit 1
    
    echo "Building javadoc JARs..."
    ./gradlew javadocJar -x test -x check || exit 1
    
    # Also try to build all at once
    echo "Running assemble to catch any missed artifacts..."
    ./gradlew assemble -x test -x check -x spotbugsMain -x spotbugsTest -x rat || true
    
    # Create java directory structure
    mkdir -p $PACKAGE_DIR/java
    
    # Copy all JARs - flat structure like native-toolchain
    echo "Copying Java artifacts..."
    find . -name "*.jar" -type f -not -path "*/src/*" -not -path "*/.gradle/*" -not -path "*/build/tmp/*" | while read jar; do
        # Get just the filename
        filename=$(basename "$jar")
        # Check if it's a real JAR (not empty)
        if [ -s "$jar" ]; then
            echo "  Copying: $filename"
            cp "$jar" $PACKAGE_DIR/java/
        fi
    done
    
    # Also create repository structure
    mkdir -p $PACKAGE_DIR/java/repository
    for module in kudu-client kudu-hive kudu-spark kudu-test-utils kudu-backup kudu-subprocess; do
        if [ -d "$module/build/libs" ]; then
            mkdir -p $PACKAGE_DIR/java/repository/$module
            cp $module/build/libs/*.jar $PACKAGE_DIR/java/repository/$module/ 2>/dev/null || true
        fi
    done
    
    # Stop Gradle daemon
    ./gradlew --stop 2>/dev/null || true
else
    echo "ERROR: gradlew not found!"
    exit 1
fi

# Create metadata files
cd $SOURCE_ROOT
GIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
echo "$GIT_HASH" > $PACKAGE_DIR/toolchain-build-hash.txt

# Copy license files
cp LICENSE.txt NOTICE.txt $PACKAGE_DIR/

# Create README
cat > $PACKAGE_DIR/README.txt << EOF
Apache Kudu $VERSION Full Package

This package contains:
- release/  : Release build of Kudu binaries and libraries
- debug/    : Debug build of Kudu binaries and libraries
- java/     : All Java artifacts (JARs, sources, javadoc, shadow/fat JARs)
  - Main JARs: kudu-*.jar
  - Source JARs: kudu-*-sources.jar
  - Test JARs: kudu-*-tests.jar
  - Test Source JARs: kudu-*-test-sources.jar
  - Javadoc JARs: kudu-*-javadoc.jar
  - All/Shadow JARs: kudu-*-all.jar (where available)
- toolchain-build-hash.txt : Git commit hash

Built on: $(date)
Host: $(hostname)
EOF

# Create the tarball
echo ""
echo "Creating tarball..."
cd $BUILD_ROOT/package
tar czf $PACKAGE_NAME.tar.gz $PACKAGE_NAME/

# Summary
echo ""
echo "================================================================================"
echo "Full build complete!"
echo "Package: $BUILD_ROOT/package/$PACKAGE_NAME.tar.gz"
echo "Size: $(du -h $PACKAGE_NAME.tar.gz | cut -f1)"
echo ""
echo "Java artifacts in package:"
cd $PACKAGE_DIR/java
ls -la *.jar 2>/dev/null | head -20 || echo "No JARs found"
echo ""
echo "Total JARs: $(ls *.jar 2>/dev/null | wc -l)"
echo "================================================================================"