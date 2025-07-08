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
# Clean up Gradle locks and caches
# This script helps resolve "Timeout waiting to lock artifact cache" errors
#
################################################################################

set -e

echo "Cleaning up Gradle locks and processes..."

# Stop all Gradle daemons gracefully
echo "Stopping Gradle daemons..."
if command -v gradle >/dev/null 2>&1; then
    gradle --stop 2>/dev/null || true
fi

# Also try with gradlew if available
SCRIPT_DIR=$(cd $(dirname $0); pwd)
if [ -f "$SCRIPT_DIR/../java/gradlew" ]; then
    cd $SCRIPT_DIR/../java
    ./gradlew --stop 2>/dev/null || true
fi

# Kill any remaining Gradle daemon processes
echo "Killing remaining Gradle processes..."
if command -v jps >/dev/null 2>&1; then
    jps | grep GradleDaemon | awk '{print $1}' | while read pid; do
        echo "  Killing Gradle daemon with PID: $pid"
        kill -9 $pid 2>/dev/null || true
    done
fi

# Also check with ps
ps aux | grep -E '[G]radleDaemon|[g]radle.*daemon' | awk '{print $2}' | while read pid; do
    echo "  Killing Gradle process with PID: $pid"
    kill -9 $pid 2>/dev/null || true
done

# Remove lock files
echo "Removing Gradle lock files..."
if [ -d ~/.gradle ]; then
    find ~/.gradle -name "*.lock" -o -name "*.lck" | while read lock; do
        echo "  Removing: $lock"
        rm -f "$lock"
    done
    
    # Remove specific problematic cache locks
    rm -f ~/.gradle/caches/modules-2/modules-2.lock 2>/dev/null || true
    rm -f ~/.gradle/caches/modules-2/metadata-*/module-metadata.lock 2>/dev/null || true
    rm -f ~/.gradle/caches/jars-*/jars-*.lock 2>/dev/null || true
fi

# Clean project-specific gradle directories
if [ -d "$SCRIPT_DIR/../java/.gradle" ]; then
    echo "Cleaning project .gradle directory..."
    rm -rf $SCRIPT_DIR/../java/.gradle/
fi

# Optional: Full cache clean (commented out by default as it's aggressive)
# Uncomment if you want to do a full clean
# echo "Removing entire Gradle cache (this will require re-downloading dependencies)..."
# rm -rf ~/.gradle/caches/

echo ""
echo "Gradle cleanup complete!"
echo ""
echo "Tips to avoid lock issues in the future:"
echo "  1. Always use --no-daemon flag: ./gradlew build --no-daemon"
echo "  2. Use --no-parallel to avoid concurrent access: ./gradlew build --no-parallel"
echo "  3. Stop daemons after build: ./gradlew --stop"
echo "  4. Set org.gradle.daemon=false in gradle.properties"
echo ""