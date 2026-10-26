#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"

echo "=========================================="
echo " H69K iStoreOS 24.10 自定义软件包准备"
echo " 暂不集成 luci-app-mt5700"
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
echo "== 3. 暂停集成 MT5700 插件 =="

# 本次测试暂不下载、不编译、不集成 MT5700。
# 清除旧工作目录，避免上一次构建遗留的源码被误识别。
rm -rf package/luci-app-mt5700

# 同时移除 .config 中可能残留的 MT5700 启用项。
if [ -f .config ]; then
  sed -i \
    '/^CONFIG_PACKAGE_luci-app-mt5700=/d' \
    .config
fi

echo "MT5700 集成已暂停。"

echo
echo "== 4. 下载 AdGuard Home LuCI 插件源码 =="

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
echo "== 5. 配置其他自定义软件包 =="

# 删除旧的重复配置，避免同一选项出现多个不同取值。
if [ -f .config ]; then
  sed -i \
    -e '/^CONFIG_PACKAGE_luci-app-fan-h69k=/d' \
    -e '/^CONFIG_PACKAGE_kmod-hwmon-pwmfan=/d' \
    -e '/^CONFIG_PACKAGE_kmod-thermal=/d' \
    -e '/^CONFIG_PACKAGE_docker=/d' \
    -e '/^CONFIG_PACKAGE_dockerd=/d' \
    -e '/^CONFIG_PACKAGE_adguardhome=/d' \
    -e '/^CONFIG_PACKAGE_luci-app-adguardhome=/d' \
    -e '/^CONFIG_PACKAGE_luci-app-mt5700=/d' \
    .config
fi

cat >> .config <<'EOF'

# H69K custom packages
CONFIG_PACKAGE_luci-app-fan-h69k=y
CONFIG_PACKAGE_kmod-hwmon-pwmfan=y
CONFIG_PACKAGE_kmod-thermal=y
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_adguardhome=y
CONFIG_PACKAGE_luci-app-adguardhome=y
EOF

echo
echo "== 6. 检查 MT5700 是否已取消 =="

if grep -q '^CONFIG_PACKAGE_luci-app-mt5700=y$' .config; then
  echo "错误：MT5700 仍然处于启用状态"
  exit 1
fi

if [ -e package/luci-app-mt5700 ]; then
  echo "错误：仍存在 package/luci-app-mt5700"
  exit 1
fi

echo "检查通过：本次构建不集成 MT5700。"

echo
echo "== 自定义软件包准备完成 =="
echo "保留：调温大师、AdGuard Home、Docker 相关配置。"
echo "OpenClash 仍由 GitHub Actions 工作流单独添加。"
