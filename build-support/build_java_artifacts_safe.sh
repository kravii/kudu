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
# Safe Java artifacts build script - avoids permission issues
# Builds all Java JARs with proper Gradle home configuration
#
################################################################################

set -e

SOURCE_ROOT=$(cd $(dirname $0)/..; pwd)
VERSION=$(cat $SOURCE_ROOT/version.txt)
OUTPUT_DIR=${OUTPUT_DIR:-$SOURCE_ROOT/build/java-artifacts}

echo "Building Kudu Java artifacts version $VERSION"
echo "Output directory: $OUTPUT_DIR"
echo "Running as user: $(whoami)"
echo "Home directory: $HOME"

# Create output directory
mkdir -p $OUTPUT_DIR

cd $SOURCE_ROOT/java

# Set Gradle user home to avoid permission issues
export GRADLE_USER_HOME=${GRADLE_USER_HOME:-$HOME/.gradle}
echo "Using GRADLE_USER_HOME: $GRADLE_USER_HOME"

# Clean up Gradle environment in the correct location
echo "Cleaning Gradle environment..."
rm -rf .gradle 2>/dev/null || true
rm -f $GRADLE_USER_HOME/caches/modules-2/modules-2.lock 2>/dev/null || true
rm -f $GRADLE_USER_HOME/caches/journal-1/journal-1.lock 2>/dev/null || true
rm -rf $GRADLE_USER_HOME/daemon/* 2>/dev/null || true

# Kill any Gradle daemons
if command -v jps >/dev/null 2>&1; then
    jps | grep GradleDaemon | awk '{print $1}' | xargs -r kill -9 2>/dev/null || true
fi

if [ ! -f "./gradlew" ]; then
    echo "ERROR: gradlew not found in $(pwd)"
    exit 1
fi

# Make sure gradlew is executable
chmod +x ./gradlew

# Set environment to avoid daemon and other issues
export GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.parallel=false -Xmx2g -Dgradle.user.home=$GRADLE_USER_HOME"

# Clean with proper Gradle home
echo "Cleaning previous build..."
./gradlew --gradle-user-home=$GRADLE_USER_HOME clean || true

# Build each type of artifact with explicit Gradle home
echo ""
echo "Building main JARs..."
./gradlew --gradle-user-home=$GRADLE_USER_HOME jar -x test -x check -x spotbugsMain -x spotbugsTest || exit 1

echo ""
echo "Building source JARs..."
./gradlew --gradle-user-home=$GRADLE_USER_HOME sourcesJar -x test -x check || exit 1

echo ""
echo "Building test JARs..."
./gradlew --gradle-user-home=$GRADLE_USER_HOME testJar -x test -x check || exit 1

echo ""
echo "Building test source JARs..."
./gradlew --gradle-user-home=$GRADLE_USER_HOME testSourcesJar -x test -x check || exit 1

echo ""
echo "Building javadoc JARs..."
./gradlew --gradle-user-home=$GRADLE_USER_HOME javadocJar -x test -x check || exit 1

echo ""
echo "Building shadow/fat JARs (if configured)..."
# Try each module that might have shadow configuration
for module in kudu-client kudu-hive kudu-spark kudu-test-utils kudu-backup kudu-subprocess kudu-spark-tools kudu-backup-tools; do
    if [ -d "$module" ]; then
        echo "  Trying shadowJar for $module..."
        ./gradlew --gradle-user-home=$GRADLE_USER_HOME :$module:shadowJar -x test -x check 2>/dev/null || echo "    No shadow configuration for $module"
    fi
done

# Copy all artifacts
echo ""
echo "Copying artifacts to $OUTPUT_DIR..."
find . -name "*.jar" -type f -not -path "*/src/*" -not -path "*/.gradle/*" -not -path "*/build/tmp/*" | while read jar; do
    filename=$(basename "$jar")
    if [ -s "$jar" ]; then
        cp -v "$jar" $OUTPUT_DIR/
    fi
done

# Clean up
echo ""
echo "Cleaning up Gradle processes..."
./gradlew --gradle-user-home=$GRADLE_USER_HOME --stop 2>/dev/null || true

# Summary
echo ""
echo "================================================================================"
echo "Java build complete!"
echo ""
echo "Artifacts in $OUTPUT_DIR:"
cd $OUTPUT_DIR
ls -la | grep "\.jar$" | head -20
echo ""
echo "JAR count by type:"
echo "  Main JARs: $(ls *[0-9].jar 2>/dev/null | grep -v -- "-" | wc -l)"
echo "  Shadow/All JARs: $(ls *-all.jar 2>/dev/null | wc -l)"
echo "  Source JARs: $(ls *-sources.jar 2>/dev/null | wc -l)"
echo "  Test JARs: $(ls *-tests.jar 2>/dev/null | wc -l)"
echo "  Test Source JARs: $(ls *-test-sources.jar 2>/dev/null | wc -l)"
echo "  Javadoc JARs: $(ls *-javadoc.jar 2>/dev/null | wc -l)"
echo ""
echo "Total JARs: $(ls *.jar 2>/dev/null | wc -l)"
echo "================================================================================"