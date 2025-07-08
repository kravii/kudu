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
# Standalone Java artifacts build script
# Builds all Java JARs including shadow/fat JARs
#
################################################################################

set -e

SOURCE_ROOT=$(cd $(dirname $0)/..; pwd)
VERSION=$(cat $SOURCE_ROOT/version.txt)
OUTPUT_DIR=${OUTPUT_DIR:-$SOURCE_ROOT/build/java-artifacts}

echo "Building Kudu Java artifacts version $VERSION"
echo "Output directory: $OUTPUT_DIR"

# Create output directory
mkdir -p $OUTPUT_DIR

cd $SOURCE_ROOT/java

# Clean up Gradle environment
echo "Cleaning Gradle environment..."
rm -rf .gradle ~/.gradle/caches/modules-2/modules-2.lock 2>/dev/null || true
if command -v jps >/dev/null 2>&1; then
    jps | grep GradleDaemon | awk '{print $1}' | xargs -r kill -9 2>/dev/null || true
fi

if [ ! -f "./gradlew" ]; then
    echo "ERROR: gradlew not found in $(pwd)"
    exit 1
fi

# Stop any existing daemons
./gradlew --stop 2>/dev/null || true

# Set environment
export GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.parallel=false -Xmx2g"

# Clean
echo "Cleaning previous build..."
./gradlew clean || true

# Build each type of artifact
echo ""
echo "Building main JARs..."
./gradlew jar -x test -x check -x spotbugsMain -x spotbugsTest -x rat

echo ""
echo "Building shadow/fat JARs (this creates the -all.jar files)..."
./gradlew shadowJar -x test -x check || echo "Some modules may not have shadow configuration"

echo ""
echo "Building source JARs..."
./gradlew sourcesJar -x test -x check

echo ""
echo "Building test JARs..."
./gradlew testJar -x test -x check

echo ""
echo "Building test source JARs..."
./gradlew testSourcesJar -x test -x check

echo ""
echo "Building javadoc JARs..."
./gradlew javadocJar -x test -x check

echo ""
echo "Running final assemble..."
./gradlew assemble -x test -x check -x spotbugsMain -x spotbugsTest -x rat || true

# Copy all artifacts
echo ""
echo "Copying artifacts to $OUTPUT_DIR..."
find . -name "*.jar" -type f -not -path "*/src/*" -not -path "*/.gradle/*" -not -path "*/build/tmp/*" | while read jar; do
    filename=$(basename "$jar")
    if [ -s "$jar" ]; then
        cp -v "$jar" $OUTPUT_DIR/
    fi
done

# Stop Gradle daemon
./gradlew --stop 2>/dev/null || true

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