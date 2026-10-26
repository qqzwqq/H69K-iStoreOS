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
    https://github.com/qqzwqq/luci-app-mt5700.git \
    package/luci-app-mt5700
fi

if [ ! -s package/luci-app-mt5700/Makefile ]; then
  echo "错误：MT5700 插件 Makefile 不存在"
  exit 1
fi


echo "== 下载 AdGuard Home LuCI 插件源码 =="

if [ -d package/luci-app-adguardhome/.git ]; then
  git -C package/luci-app-adguardhome pull --ff-only
else
  rm -rf package/luci-app-adguardhome
  git clone --depth=1 \
    https://github.com/rufengsuixing/luci-app-adguardhome.git \
    package/luci-app-adguardhome
fi

adguard_dir="package/luci-app-adguardhome"

for f in \
  Makefile \
  root/etc/init.d/AdGuardHome \
  root/etc/config/AdGuardHome \
  root/usr/share/AdGuardHome/update_core.sh \
  root/usr/share/AdGuardHome/links.txt \
  root/usr/share/AdGuardHome/AdGuardHome_template.yaml
do
  if [ ! -s "$adguard_dir/$f" ]; then
    echo "错误：AdGuard Home 缺少必要文件：$f"
    exit 1
  fi
done

grep -q 'define Package/luci-app-adguardhome' \
  "$adguard_dir/Makefile" || {
    echo "错误：未找到 luci-app-adguardhome 软件包定义"
    exit 1
  }

echo "== 启用自定义软件包 =="

cat >> .config <<'EOF'

# H69K custom packages
CONFIG_PACKAGE_luci-app-fan-h69k=y
CONFIG_PACKAGE_luci-app-mt5700=y
CONFIG_PACKAGE_kmod-hwmon-pwmfan=y
CONFIG_PACKAGE_kmod-thermal=y
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_luci-app-adguardhome=y
EOF

echo "AdGuard Home 前端源码和必要文件检查完成"

echo "插件源码准备完成"
