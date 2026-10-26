#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo "::error::脚本第 ${LINENO} 行执行失败，退出码 ${rc}"; exit "$rc"' ERR
set -x

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"

echo "===== 1. 检查 H69K 设备定义 ====="

grep -R -q 'hinlink_opc-h6xk' target/linux/rockchip || {
  echo "错误：25.12 源码中没有找到 H69K 设备定义"
  exit 1
}

grep -R -q 'hinlink,opc-h69k' target/linux/rockchip || {
  echo "错误：没有找到 hinlink,opc-h69k 兼容标识"
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmpdir"; if [ "$rc" -ne 0 ]; then echo "::error::插件准备失败，退出码 $rc"; fi; exit "$rc"' EXIT

echo "===== 2. 准备 H69K 风扇插件 ====="

archive="$GITHUB_WORKSPACE/luci-app-fan-h69k-build-source-1.3-25.zip"

if [ ! -s "$archive" ]; then
  echo "::error::仓库中缺少风扇插件 ZIP 文件：$archive"
  exit 1
fi

unzip -q "$archive" -d "$tmpdir"

fan_makefile="$(
  find "$tmpdir" -type f \
    -path '*/luci-app-fan-h69k-build-source/Makefile' \
    -print -quit
)"

if [ -z "$fan_makefile" ]; then
  echo "::error::风扇插件 ZIP 中没有找到预期的 Makefile"
  find "$tmpdir" -maxdepth 4 -type f | head -80
  exit 1
fi

mkdir -p package/luci-app-fan-h69k
cp -a "$(dirname "$fan_makefile")/." package/luci-app-fan-h69k/
test -s package/luci-app-fan-h69k/Makefile

echo "===== 3. 下载 MT5700 插件 ====="

rm -rf package/luci-app-mt5700
git clone --depth=1 \
  https://github.com/LianXia233/luci-app-mt5700.git \
  package/luci-app-mt5700
test -s package/luci-app-mt5700/Makefile

echo "===== 4. 下载 AdGuardHome LuCI 插件 ====="

rm -rf package/luci-app-adguardhome
git clone --depth=1 \
  https://github.com/rufengsuixing/luci-app-adguardhome.git \
  package/luci-app-adguardhome
test -s package/luci-app-adguardhome/Makefile

echo "===== 5. 下载 OpenClash 插件 ====="

git clone --depth=1 \
  https://github.com/vernesong/OpenClash.git \
  "$tmpdir/OpenClash"
test -s "$tmpdir/OpenClash/luci-app-openclash/Makefile"

rm -rf package/luci-app-openclash
mkdir -p package/luci-app-openclash
cp -a "$tmpdir/OpenClash/luci-app-openclash/." \
  package/luci-app-openclash/
test -s package/luci-app-openclash/Makefile

echo "===== 6. 检查 AdGuardHome 插件文件 ====="

for f in root/etc/init.d/AdGuardHome root/etc/config/AdGuardHome; do
  if [ ! -s "package/luci-app-adguardhome/$f" ]; then
    echo "::error::AdGuardHome 插件缺少文件：$f"
    exit 1
  fi
done

echo "===== 7. 启用 H69K 所需软件包 ====="

cat >> .config <<'EOF'

# H69K custom packages
CONFIG_PACKAGE_luci-app-fan-h69k=y
CONFIG_PACKAGE_luci-app-mt5700=y
CONFIG_PACKAGE_kmod-hwmon-pwmfan=y
CONFIG_PACKAGE_kmod-thermal=y
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_adguardhome=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-openclash=y
EOF

echo "===== 插件源码准备完成 ====="
