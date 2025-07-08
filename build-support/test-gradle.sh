#!/bin/bash

echo "Testing Gradle setup..."

cd $(dirname $0)/../java

echo "Current directory: $(pwd)"
echo ""

# Check if gradlew exists
if [ -f "./gradlew" ]; then
    echo "gradlew found"
    echo "gradlew permissions: $(ls -la ./gradlew)"
    echo ""
    
    # Check Java version
    echo "Java version:"
    java -version 2>&1
    echo ""
    
    # Try different Gradle commands
    echo "Testing: ./gradlew --version"
    ./gradlew --version || echo "FAILED: gradlew --version"
    echo ""
    
    echo "Testing: ./gradlew tasks"
    ./gradlew tasks | head -20 || echo "FAILED: gradlew tasks"
    echo ""
    
    echo "Testing: GRADLE_OPTS=-Dorg.gradle.daemon=false ./gradlew tasks"
    GRADLE_OPTS="-Dorg.gradle.daemon=false" ./gradlew tasks | head -20 || echo "FAILED with env var"
    echo ""
    
else
    echo "ERROR: gradlew not found in $(pwd)"
fi