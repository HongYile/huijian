#!/usr/bin/env bash
# 编译回笺共用核心（Rust）。用法：core/build.sh mac | ios | ios-sim | android
# 产物：
#   mac / ios / ios-sim → core/target/<目标>/release/libhuijian_core.a（Swift 用 -I core/include 引入 HuijianCore 模块）
#   android            → android/app/src/main/jniLibs/arm64-v8a/libhuijian_core.so
# 需要：Rust（rustup，对应 target 已安装）；安卓另需 NDK（ANDROID_NDK_HOME，或 ~/Library/Android/sdk/ndk 下最新的一个）。
set -euo pipefail
cd "$(dirname "$0")"
CARGO="${CARGO:-$(command -v cargo || echo "$HOME/.cargo/bin/cargo")}"
JOBS="${CORE_JOBS:-2}"   # 默认只用 2 个核心编译，避免机器卡顿
# 依赖的源码路径（panic 位置等）会编进产物：把主目录换成 ~，产物里不带本机用户名
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~"

case "${1:-}" in
  mac)     T=aarch64-apple-darwin;  export MACOSX_DEPLOYMENT_TARGET=14.0 ;;
  ios)     T=aarch64-apple-ios;     export IPHONEOS_DEPLOYMENT_TARGET=17.0 ;;
  ios-sim) T=aarch64-apple-ios-sim; export IPHONEOS_DEPLOYMENT_TARGET=17.0 ;;
  android)
    T=aarch64-linux-android
    NDK="${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1)}"
    [ -d "$NDK" ] || { echo "找不到 Android NDK：设置 ANDROID_NDK_HOME" >&2; exit 1; }
    BIN=$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/bin | head -1)
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$BIN/aarch64-linux-android26-clang"
    export AR_aarch64_linux_android="$BIN/llvm-ar" CC_aarch64_linux_android="$BIN/aarch64-linux-android26-clang"
    "$CARGO" rustc --release -j "$JOBS" --lib --target $T --features android --crate-type cdylib
    OUT=../android/app/src/main/jniLibs/arm64-v8a
    mkdir -p $OUT
    cp -p target/$T/release/libhuijian_core.so $OUT/libhuijian_core.so
    echo "✅ $OUT/libhuijian_core.so（$(du -k $OUT/libhuijian_core.so | cut -f1) KB）"
    exit 0 ;;
  *) echo "用法：$0 mac | ios | ios-sim | android" >&2; exit 2 ;;
esac
"$CARGO" rustc --release -j "$JOBS" --lib --target $T --crate-type staticlib
echo "✅ core/target/$T/release/libhuijian_core.a"
