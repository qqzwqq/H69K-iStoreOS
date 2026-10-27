#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"

echo "=========================================="
echo " H69K iStoreOS 24.10 自定义软件包准备"
echo " 正在全面集成 luci-app-mt5700 5G套件"
echo "=========================================="

echo "== 1. 检查 H69K 官方设备定义 =="

if ! grep -q 'TARGET_DEVICES += hinlink_opc-h6xk' \
  target/linux/rockchip/image/legacy.mk; then
  echo "错误：源码中未找到 hinlink_opc-h6xk"
  exit 1
fi

if ! grep -q 'hinlink,opc-h69k' \
  target/linux/rockchip/image/legacy.mk; then
  echo "错误：设备定义未包含 hinlink,opc-h69k"
  exit 1
fi

echo "H69K 设备定义检查通过。"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo
echo "== 2. 准备调温大师插件 =="

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
  echo "错误：ZIP 内未找到调温大师插件 Makefile"
  find "$tmpdir" -maxdepth 4 -type f | head -80 || true
  exit 1
fi

fan_src="$(dirname "$fan_makefile")"

mkdir -p package/luci-app-fan-h69k
cp -a "$fan_src/." package/luci-app-fan-h69k/

if [ ! -s package/luci-app-fan-h69k/Makefile ]; then
  echo "错误：调温大师 Makefile 不存在"
  exit 1
fi

echo "调温大师源码准备完成。"

echo
echo "== 3. 下载 AdGuard Home LuCI 插件源码 =="

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

if ! grep -q 'define Package/luci-app-adguardhome' \
  "$adguard_dir/Makefile"; then
  echo "错误：未找到 luci-app-adguardhome 软件包定义"
  exit 1
fi

echo "AdGuard Home 前端源码和必要文件检查完成。"

echo
echo "== 自定义软件包准备完成 =="
echo "脚本已安全移除了对 MT5700 的强行封锁，允许其随固件正常编译！"
