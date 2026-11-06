include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fan-h69k
PKG_VERSION:=1.3
PKG_RELEASE:=25

LUCI_TITLE:=LuCI PWM fan control for HINLINK OPC-H69K
LUCI_DEPENDS:=+luci-base +luci-compat +luci-lua-runtime +kmod-hwmon-pwmfan
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
