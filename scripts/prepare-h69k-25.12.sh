#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"

readonly FAN_ARCHIVE="${GITHUB_WORKSPACE}/luci-app-fan-h69k-build-source-1.3-25.zip"
readonly FAN_PACKAGE="package/luci-app-fan-h69k"

die() {
  printf '\n::error::%s\n' "$*" >&2
  exit 1
}

need_file() {
  [[ -s "$1" ]] || die "缺少必要文件或文件为空：$1"
}

echo "=========================================="
echo " H69K iStoreOS 25.12 自定义软件包准备"
echo "=========================================="

# 1. 检查 H69K 硬件基线
need_file target/linux/rockchip/image/legacy.mk
grep -qE 'TARGET_DEVICES[[:space:]]*\+=[[:space:]]*hinlink_opc-h6xk' target/linux/rockchip/image/legacy.mk ||
  die "新分支源码中未找到 hinlink_opc-h6xk 设备定义"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 2. 固定使用经过确认的调温大师 1.3-25 源码包
echo "===== 准备调温大师 1.3-25 ====="
need_file "$FAN_ARCHIVE"
unzip -q "$FAN_ARCHIVE" -d "$tmpdir" ||
  die "调温大师 1.3-25 源码 ZIP 解压失败"

fan_makefile="$(
  find "$tmpdir" -type f \
    -path '*/luci-app-fan-h69k-build-source/Makefile' \
    -print -quit
)"

# 兼容压缩包顶层目录名称变化，但不允许静默跳过
if [[ -z "$fan_makefile" ]]; then
  fan_makefile="$(
    find "$tmpdir" -type f \
      -path '*/luci-app-fan-h69k/Makefile' \
      -print -quit
  )"
fi

[[ -n "$fan_makefile" ]] ||
  die "1.3-25 压缩包内未找到 luci-app-fan-h69k Makefile"

grep -qE \
  'define Package/luci-app-fan-h69k|^PKG_NAME[[:space:]]*:?=[[:space:]]*luci-app-fan-h69k' \
  "$fan_makefile" ||
  die "压缩包内 Makefile 不是 luci-app-fan-h69k"

rm -rf "$FAN_PACKAGE"
mkdir -p "$FAN_PACKAGE"
cp -a "$(dirname "$fan_makefile")/." "$FAN_PACKAGE/"

need_file "$FAN_PACKAGE/Makefile"
grep -qE \
  'define Package/luci-app-fan-h69k|^PKG_NAME[[:space:]]*:?=[[:space:]]*luci-app-fan-h69k' \
  "$FAN_PACKAGE/Makefile" ||
  die "调温大师源码复制后校验失败"

echo "调温大师源码已固定为仓库内的 1.3-25 ZIP："
grep -E '^(PKG_NAME|PKG_VERSION|PKG_RELEASE)[[:space:]]*[:?+]?=' "$FAN_PACKAGE/Makefile" || true

# 3. 准备 AdGuardHome（保留原有处理方式）
if [[ ! -d package/luci-app-adguardhome ]]; then
  git clone --depth=1 https://github.com/rufengsuixing/luci-app-adguardhome.git package/luci-app-adguardhome
fi

need_file package/luci-app-adguardhome/Makefile

echo "25.12 分支自定义包前置源加载完成。"
