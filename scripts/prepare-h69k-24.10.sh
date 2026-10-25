#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"

echo "== 检查 H69K 官方设备定义 =="

grep -q 'TARGET_DEVICES += hinlink_opc-h6xk' \
  target/linux/rockchip/image/legacy.mk || {
    echo "错误：源码中未找到 hinlink_opc-h6xk"
    exit 1
  }

grep -q 'hinlink,opc-h69k' \
  target/linux/rockchip/image/legacy.mk || {
    echo "错误：设备定义未包含 hinlink,opc-h69k"
    exit 1
  }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "== 准备调温大师插件 =="

archive="$GITHUB_WORKSPACE/luci-app-fan-h69k-build-source-1.3-25.zip"

if [ ! -s "$archive" ]; then
  echo "错误：仓库根目录缺少调温大师源码 ZIP："
  echo "$archive"
  exit 1
fi

unzip -q "$archive" -d "$tmpdir"

fan_makefile="$(
  find "$tmpdir" -type f \
    -path '*/luci-app-fan-h69k-build-source/Makefile' \
    -print -quit
)"

if [ -z "$fan_makefile" ]; then
  echo "错误：ZIP 内未找到插件 Makefile"
  find "$tmpdir" -maxdepth 4 -type f | head -80
  exit 1
fi

mkdir -p package/luci-app-fan-h69k

fan_src="$(dirname "$fan_makefile")"
cp -a "$fan_src/." package/luci-app-fan-h69k/

if [ ! -s package/luci-app-fan-h69k/Makefile ]; then
  echo "错误：调温大师 Makefile 不存在"
  exit 1
fi

echo "== 下载 MT5700 插件源码 =="

if [ -d package/luci-app-mt5700/.git ]; then
  git -C package/luci-app-mt5700 pull --ff-only
else
  rm -rf package/luci-app-mt5700

  git clone --depth=1 \
    https://github.com/LianXia233/luci-app-mt5700.git \
    package/luci-app-mt5700
fi

if [ ! -s package/luci-app-mt5700/Makefile ]; then
  echo "错误：MT5700 插件 Makefile 不存在"
  exit 1
fi

echo "== 启用自定义软件包 =="

cat >> .config <<'EOF'

# H69K custom packages
CONFIG_PACKAGE_luci-app-fan-h69k=y
CONFIG_PACKAGE_luci-app-mt5700=y
CONFIG_PACKAGE_kmod-hwmon-pwmfan=y
CONFIG_PACKAGE_kmod-thermal=y
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
EOF


echo "== 启用 AdGuard Home =="

cat >> .config <<'EOF'
CONFIG_PACKAGE_adguardhome=y
CONFIG_PACKAGE_luci-app-adguardhome=y
EOF

echo "插件源码准备完成"
