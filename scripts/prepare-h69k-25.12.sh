#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"

echo "=========================================="
echo " H69K iStoreOS 25.12 自定义软件包准备"
echo "=========================================="

# 1. 检查固件内是否有 H69K 的硬件基线
if ! grep -q 'TARGET_DEVICES += hinlink_opc-h6xk' target/linux/rockchip/image/legacy.mk; then
  echo "错误：新分支源码中未找到 hinlink_opc-h6xk 设备定义"
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 2. 准备调温大师
archive="$GITHUB_WORKSPACE/luci-app-fan-h69k-build-source-1.3-25.zip"
if [ -s "$archive" ]; then
  unzip -q "$archive" -d "$tmpdir"
  fan_makefile="$(find "$tmpdir" -type f -path '*/luci-app-fan-h69k-build-source/Makefile' -print -quit)"
  if [ -n "$fan_makefile" ]; then
    mkdir -p package/luci-app-fan-h69k
    cp -a "$(dirname "$fan_makefile")/." package/luci-app-fan-h69k/
  fi
fi

# 3. 准备 AdGuardHome
if [ ! -d package/luci-app-adguardhome ]; then
  git clone --depth=1 https://github.com package/luci-app-adguardhome
fi

echo "25.12 分支自定义包前置源加载完成。"
