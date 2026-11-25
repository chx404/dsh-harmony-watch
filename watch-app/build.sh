#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export OHOS_BASE_SDK_HOME="${OHOS_BASE_SDK_HOME:-/root/workspace/harmony/sdk/linux}"
export DEVECO_SDK_HOME="$OHOS_BASE_SDK_HOME"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-arm64}"
export PATH="$JAVA_HOME/bin:$PATH"
node node_modules/@ohos/hvigor/bin/hvigor.js --mode module -p product=default assembleHap --no-daemon
mkdir -p dist
cp entry/build/default/outputs/default/entry-default-unsigned.hap dist/dsh-watch-2.2.0-monochrome-unsigned.hap
ls -lh dist/dsh-watch-2.2.0-monochrome-unsigned.hap
