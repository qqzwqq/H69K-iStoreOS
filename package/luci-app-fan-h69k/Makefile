include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fan-h69k
PKG_VERSION:=1.4.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=H69K Community

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-fan-h69k
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=HINLINK OPC-H69K Fan Control (Tuning Master)
  DEPENDS:=+luci-base +luci-compat +luci-lua-runtime +kmod-hwmon-pwmfan
  PKGARCH:=all
endef

define Package/luci-app-fan-h69k/description
 LuCI PWM fan control for HINLINK OPC-H69K with kernel, manual curve,
 off and full-speed modes.
endef

define Build/Compile
endef

define Package/luci-app-fan-h69k/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./etc/config/hinlinkfan $(1)/etc/config/hinlinkfan
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./etc/init.d/hinlinkfaninit $(1)/etc/init.d/hinlinkfaninit
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./etc/uci-defaults/89-hinlinkfan-migrate $(1)/etc/uci-defaults/89-hinlinkfan-migrate
	$(INSTALL_BIN) ./etc/uci-defaults/luci-app-fan-h69k $(1)/etc/uci-defaults/luci-app-fan-h69k
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./lib/lua/luci/controller/hinlinkfan.lua $(1)/usr/lib/lua/luci/controller/hinlinkfan.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./lib/lua/luci/model/cbi/hinlinkfan.lua $(1)/usr/lib/lua/luci/model/cbi/hinlinkfan.lua
	$(INSTALL_DIR) $(1)/usr/lib/hinlinkfan
	$(INSTALL_DATA) ./lib/hinlinkfan/common.sh $(1)/usr/lib/hinlinkfan/common.sh
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./sbin/hinlinkfan-daemon $(1)/usr/sbin/hinlinkfan-daemon
endef

$(eval $(call BuildPackage,luci-app-fan-h69k))
