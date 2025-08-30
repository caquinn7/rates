#!/bin/bash

# Script to run tests for all Gleam apps in the rates project
# Usage: ./gleam_test.sh [app1 app2 app3...]

set -e  # Exit on any error

RATES_DIR="/Users/caquinn/rates"

# Use command line args if provided, otherwise use default order
if [ $# -gt 0 ]; then
    APPS=("$@")
else
    APPS=("shared" "client" "server")
fi

for app in "${APPS[@]}"; do
    app_dir="$RATES_DIR/$app"
    
    if [ -d "$app_dir" ]; then
        cd "$app_dir"
        gleam test;
    else
        echo "⚠️  warning: $app directory not found at $app_dir"
    fi
    echo ""
done