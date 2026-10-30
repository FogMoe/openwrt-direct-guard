# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

PKG_NAME:=direct-guard
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Kc <i@scarletkc.com>
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/direct-guard
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Firewall
  TITLE:=Fail-closed egress guard for selected destinations
  URL:=https://github.com/FogMoe/openwrt-direct-guard
  PKGARCH:=all
endef

define Package/direct-guard/description
  direct-guard rejects traffic to selected domains and address ranges
  whenever it would leave the router through an interface that is not
  explicitly allowed, for example while a transparent proxy restarts or
  after it crashes. Domains are resolved into sets by dnsmasq-full.
endef

define Package/direct-guard/conffiles
/etc/config/direct-guard
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/direct-guard/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/direct-guard.sh $(1)/usr/sbin/direct-guard
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/direct-guard.init $(1)/etc/init.d/direct-guard
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/direct-guard.config $(1)/etc/config/direct-guard
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/direct-guard.uci-defaults $(1)/etc/uci-defaults/90-direct-guard
	$(INSTALL_DIR) $(1)/usr/share/direct-guard
	$(INSTALL_BIN) ./files/firewall.include $(1)/usr/share/direct-guard/firewall.include
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/direct-guard.keep $(1)/lib/upgrade/keep.d/direct-guard
endef

define Package/direct-guard/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE}" = 1 ] && exit 0
/usr/sbin/direct-guard uninstall
exit 0
endef

$(eval $(call BuildPackage,direct-guard))
