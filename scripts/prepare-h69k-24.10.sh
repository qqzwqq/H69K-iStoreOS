#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

: "${GITHUB_WORKSPACE:?错误：GITHUB_WORKSPACE 未设置}"

readonly FAN_ARCHIVE="${GITHUB_WORKSPACE}/luci-app-fan-h69k-build-source-1.3-25.zip"
readonly FAN_PACKAGE="package/luci-app-fan-h69k"
readonly AGH_PACKAGE="package/luci-app-adguardhome"
readonly AGH_REPO="https://github.com/rufengsuixing/luci-app-adguardhome.git"

log() {
  printf '\n[%s] %s\n' "$(date -u '+%H:%M:%S UTC')" "$*"
}

die() {
  printf '\n::error::%s\n' "$*" >&2
  exit 1
}

need_file() {
  [[ -s "$1" ]] || die "缺少必要文件或文件为空：$1"
}

log "H69K iStoreOS 24.10 自定义软件包准备开始"

# 1. 确认在正确的源码根目录执行
[[ -f Makefile && -d target/linux/rockchip && -d package ]] ||
  die "当前目录不是有效的 iStoreOS/OpenWrt 源码根目录：$(pwd)"

log "1/4 检查 H69K 设备定义"

image_mk="target/linux/rockchip/image/legacy.mk"
need_file "$image_mk"

grep -qE 'TARGET_DEVICES[[:space:]]*\+=[[:space:]]*hinlink_opc-h6xk' "$image_mk" ||
  die "未找到 HINLINK OPC-H6xK 设备条目：hinlink_opc-h6xk"

if ! grep -R -l \
  --include='*.dts' \
  --include='*.dtsi' \
  --include='*.mk' \
  'hinlink,opc-h69k' \
  target/linux/rockchip >/dev/null 2>&1; then
  die "未找到设备兼容字符串：hinlink,opc-h69k"
fi

log "H69K 设备定义检查通过"

# 使用临时目录解压，脚本退出时自动清理
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 2. 准备调温大师插件
log "2/4 准备调温大师插件"

need_file "$FAN_ARCHIVE"

unzip -q "$FAN_ARCHIVE" -d "$tmpdir" ||
  die "调温大师源码 ZIP 解压失败"

fan_makefile="$(
  find "$tmpdir" -type f \
    -path '*/luci-app-fan-h69k-build-source/Makefile' \
    -print -quit
)"

# 兼容压缩包顶层目录名称变化
if [[ -z "$fan_makefile" ]]; then
  fan_makefile="$(
    find "$tmpdir" -type f \
      -path '*/luci-app-fan-h69k/Makefile' \
      -print -quit
  )"
fi

if [[ -z "$fan_makefile" ]]; then
  find "$tmpdir" -maxdepth 5 -type f -print | head -80 >&2 || true
  die "ZIP 内未找到调温大师插件 Makefile"
fi

fan_src="$(dirname "$fan_makefile")"

grep -qE \
  'define Package/luci-app-fan-h69k|^PKG_NAME[[:space:]]*:?=[[:space:]]*luci-app-fan-h69k' \
  "$fan_makefile" ||
  die "找到的 Makefile 不是 luci-app-fan-h69k 软件包"

# 清理旧版本，避免残留文件进入本次编译
rm -rf "$FAN_PACKAGE"
mkdir -p "$FAN_PACKAGE"
cp -a "$fan_src/." "$FAN_PACKAGE/"

need_file "$FAN_PACKAGE/Makefile"

log "调温大师插件准备完成"

# 3. 准备 AdGuard Home LuCI 插件
log "3/4 准备 AdGuard Home LuCI 插件"

# 默认使用 main；需要固定版本时可在工作流设置 AGH_REPO_REF
agh_ref="${AGH_REPO_REF:-main}"

# 清理旧目录，保证重复运行结果一致
rm -rf "$AGH_PACKAGE"

git clone --depth=1 --branch "$agh_ref" \
  "$AGH_REPO" "$AGH_PACKAGE" ||
  die "AdGuard Home 插件克隆失败，ref：$agh_ref"

for f in \
  Makefile \
  root/etc/init.d/AdGuardHome \
  root/etc/config/AdGuardHome \
  root/usr/share/AdGuardHome/update_core.sh \
  root/usr/share/AdGuardHome/links.txt \
  root/usr/share/AdGuardHome/AdGuardHome_template.yaml
do
  need_file "$AGH_PACKAGE/$f"
done

grep -q 'define Package/luci-app-adguardhome' \
  "$AGH_PACKAGE/Makefile" ||
  die "AdGuard Home Makefile 中未找到软件包定义"

log "AdGuard Home 插件检查通过"

# 4. MT5700 统一由 GitHub Actions 工作流负责
log "4/4 检查 MT5700 集成步骤"

if [[ -d package/luci-app-mt5700 ]]; then
  log "检测到 MT5700 源码目录；保留现有目录，不重复覆盖"
else
  log "MT5700 将由工作流后续步骤克隆"
fi

log "所有自定义软件包准备步骤完成"
