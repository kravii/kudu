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
# Creates a tar.gz with:
# - release/ (release build binaries)
# - debug/ (debug build binaries)  
# - java/ (Java artifacts)
# - toolchain-build-hash.txt
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

# Parse command line options
SKIP_DEBUG=0
SKIP_RELEASE=0
SKIP_JAVA=0
SKIP_THIRDPARTY=0
SKIP_JAVA_TESTS=0
CLEAN_GRADLE_CACHE=0

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --skip-debug      Skip building debug binaries"
    echo "  --skip-release    Skip building release binaries"
    echo "  --skip-java       Skip building Java artifacts"
    echo "  --skip-thirdparty Skip building thirdparty dependencies"
    echo "  --skip-java-tests Skip running Java tests"
    echo "  --clean-gradle    Clean Gradle cache before building"
    echo "  --help            Show this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-debug)
            SKIP_DEBUG=1
            shift
            ;;
        --skip-release)
            SKIP_RELEASE=1
            shift
            ;;
        --skip-java)
            SKIP_JAVA=1
            shift
            ;;
        --skip-thirdparty)
            SKIP_THIRDPARTY=1
            shift
            ;;
        --skip-java-tests)
            SKIP_JAVA_TESTS=1
            shift
            ;;
        --clean-gradle)
            CLEAN_GRADLE_CACHE=1
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

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
if [ "$SKIP_THIRDPARTY" -eq 0 ]; then
    echo "Building thirdparty dependencies..."
    cd $SOURCE_ROOT
    $SOURCE_ROOT/build-support/enable_devtoolset.sh \
        $THIRDPARTY_DIR/build-if-necessary.sh
else
    echo "Skipping thirdparty build (--skip-thirdparty specified)"
fi

# Function to build Kudu with specified build type
build_kudu() {
    local BUILD_TYPE=$1
    local BUILD_DIR=$BUILD_ROOT/$(echo $BUILD_TYPE | tr '[:upper:]' '[:lower:]')
    local INSTALL_DIR=$PACKAGE_DIR/$(echo $BUILD_TYPE | tr '[:upper:]' '[:lower:]')
    
    echo "Building Kudu in $BUILD_TYPE mode..."
    
    # Create build directory
    mkdir -p $BUILD_DIR
    cd $BUILD_DIR
    
    # Clean any existing CMake cache
    rm -rf CMakeCache.txt CMakeFiles
    
    # Configure
    echo "Configuring $BUILD_TYPE build..."
    $SOURCE_ROOT/build-support/enable_devtoolset.sh \
        $THIRDPARTY_DIR/installed/common/bin/cmake $SOURCE_ROOT \
        -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DKUDU_LINK=dynamic
    
    # Build
    echo "Building $BUILD_TYPE binaries..."
    make -j$NUM_PROCS
    
    # Install to package directory
    echo "Installing $BUILD_TYPE build to package directory..."
    make install DESTDIR=
    
    # Copy additional files that might not be installed by make install
    if [ -d "$BUILD_DIR/bin" ]; then
        cp -n $BUILD_DIR/bin/* $INSTALL_DIR/bin/ 2>/dev/null || true
    fi
    
    # Strip binaries for release builds to reduce size
    if [ "$BUILD_TYPE" = "RELEASE" ]; then
        echo "Stripping release binaries..."
        find $INSTALL_DIR/bin -type f -executable -exec strip {} \; 2>/dev/null || true
        find $INSTALL_DIR/lib -name "*.so*" -exec strip {} \; 2>/dev/null || true
    fi
}

# Build debug version
if [ "$SKIP_DEBUG" -eq 0 ]; then
    build_kudu "DEBUG"
else
    echo "Skipping debug build (--skip-debug specified)"
fi

# Build release version
if [ "$SKIP_RELEASE" -eq 0 ]; then
    build_kudu "RELEASE"
else
    echo "Skipping release build (--skip-release specified)"
fi

# Function to clean up Gradle locks
cleanup_gradle_locks() {
    echo "Cleaning up Gradle locks..."
    # Kill any running Gradle daemons
    if command -v jps >/dev/null 2>&1; then
        jps | grep GradleDaemon | awk '{print $1}' | xargs -r kill -9 2>/dev/null || true
    fi
    
    # Remove lock files
    find ~/.gradle -name "*.lock" -o -name "*.lck" | xargs -r rm -f 2>/dev/null || true
    
    # Stop Gradle daemon gracefully
    if [ -f "./gradlew" ]; then
        ./gradlew --stop 2>/dev/null || true
    fi
    
    # Wait a bit for cleanup
    sleep 2
}

# Function to build Java with retry logic
build_java_with_retry() {
    local MAX_RETRIES=3
    local RETRY_COUNT=0
    local BUILD_SUCCESS=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ $BUILD_SUCCESS -eq 0 ]; do
        if [ $RETRY_COUNT -gt 0 ]; then
            echo "Retry attempt $RETRY_COUNT of $MAX_RETRIES..."
            cleanup_gradle_locks
        fi
        
        # Build command with options
        local GRADLE_OPTS="--no-daemon --no-parallel"
        local GRADLE_TASKS="clean assemble"
        
        if [ "$SKIP_JAVA_TESTS" -eq 1 ]; then
            GRADLE_OPTS="$GRADLE_OPTS -x test -x check"
        fi
        
        # Try to build
        if ./gradlew $GRADLE_TASKS $GRADLE_OPTS; then
            BUILD_SUCCESS=1
            echo "Java build successful!"
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo "Build failed, will retry after cleanup..."
                sleep 5
            fi
        fi
    done
    
    return $((1 - BUILD_SUCCESS))
}

# Build Java artifacts
if [ "$SKIP_JAVA" -eq 0 ]; then
    echo "Building Java artifacts..."
    cd $SOURCE_ROOT/java
    
    # Clean Gradle cache if requested
    if [ "$CLEAN_GRADLE_CACHE" -eq 1 ]; then
        echo "Cleaning Gradle cache..."
        rm -rf ~/.gradle/caches/modules-2/
        rm -rf ~/.gradle/caches/jars-*
        rm -rf .gradle/
    fi
    
    # Clean up any stale locks before starting
    cleanup_gradle_locks
    
    # Use gradlew to build Java artifacts
    if [ -f "./gradlew" ]; then
        if build_java_with_retry; then
            # Create java directory in package
            mkdir -p $PACKAGE_DIR/java
            
            # Copy built JARs
            find . -name "*.jar" -not -path "*/src/*" -not -path "*/.gradle/*" -not -path "*/test/*" | while read jar; do
                # Create directory structure
                jar_dir=$(dirname $jar)
                mkdir -p $PACKAGE_DIR/java/$jar_dir
                cp $jar $PACKAGE_DIR/java/$jar_dir/
            done
            
            # Copy pom files for Maven compatibility
            find . -name "pom.xml" | while read pom; do
                pom_dir=$(dirname $pom)
                mkdir -p $PACKAGE_DIR/java/$pom_dir
                cp $pom $PACKAGE_DIR/java/$pom_dir/
            done
        else
            echo "ERROR: Java build failed after $MAX_RETRIES attempts"
            echo "You can skip Java build with --skip-java option"
            exit 1
        fi
    else
        echo "WARNING: gradlew not found, skipping Java build"
    fi
    
    # Clean up Gradle daemon after build
    cleanup_gradle_locks
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
- debug/    : Debug build of Kudu binaries and libraries
- release/  : Release build of Kudu binaries and libraries  
- java/     : Java client libraries and artifacts
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