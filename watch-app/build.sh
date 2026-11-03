#!/bin/bash
set -e
cd "$(dirname "$0")"
export DEVECO_SDK_HOME=/root/workspace/harmony/sdk/linux
export OHOS_BASE_SDK_HOME="$DEVECO_SDK_HOME"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export PATH="$JAVA_HOME/bin:$PATH"
../node-v18.20.4-linux-arm64/bin/node node_modules/@ohos/hvigor/bin/hvigor.js --mode module -p product=default assembleHap
ls -lh entry/build/default/outputs/default/*.hap
