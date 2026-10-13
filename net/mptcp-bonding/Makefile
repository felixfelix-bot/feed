# SPDX-License-Identifier: GPL-2.0-only
#
# mptcp-bonding — MPTCP multi-WAN bonding client (pure files, no compilation).
#
# Vendored as a src-link feed package. Ships kernel MPTCP enablement (sysctl),
# an ss-redir procd init toward the convergence-point VPS, UCI config schema,
# and a setup-bond helper. The matching server is deployed by Ansible from
# c03rad0r/tg-mptcp-server (shadowsocks-libev + glorytun).

include $(TOPDIR)/rules.mk

PKG_NAME:=mptcp-bonding
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=TollGate <tollgate@tollgate.me>
PKG_LICENSE:=GPL-2.0-only

# No source to fetch — this package ships only config/init/helper files.
PKG_BUILD_DEPENDS:=shadowsocks-libev-ss-redir

include $(INCLUDE_DIR)/package.mk

define Package/mptcp-bonding
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Routing and Redirection
  TITLE:=MPTCP Multi-WAN Bonding Client
  URL:=https://github.com/c03rad0r/tg-mptcp-server
  DEPENDS:=+shadowsocks-libev-ss-redir +ip-full +kmod-sched
endef

define Package/mptcp-bonding/description
  MPTCP multi-WAN bonding client for OpenWrt. Bonds multiple WAN links into
  a single logical tunnel via MPTCP subflows, with traffic redirected through
  ss-redir to a convergence-point VPS that holds the server side.

  The matching SERVER is deployed by Ansible from c03rad0r/tg-mptcp-server
  (shadowsocks-libev + glorytun on a host with a stable public IP).

  STATUS: ready — complete MPTCP bonding client with shadowsocks integration
  and dynamic endpoint management. Configure the server endpoint in
  /etc/config/mptcp-bonding before enabling.
endef

define Package/mptcp-bonding/conffiles
/etc/config/mptcp-bonding
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/mptcp-bonding/install
	# procd init script
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/mptcp-bonding $(1)/etc/init.d/mptcp-bonding

	# UCI config schema
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/mptcp-bonding $(1)/etc/config/mptcp-bonding

	# sysctl: enable MPTCP + configure path manager / subflow limits
	$(INSTALL_DIR) $(1)/etc/sysctl.d
	$(INSTALL_DATA) ./files/etc/sysctl.d/mptcp-bonding.conf $(1)/etc/sysctl.d/mptcp-bonding.conf

	# setup-bond helper: dynamic endpoint management
	$(INSTALL_DIR) $(1)/usr/lib/mptcp-bonding
	$(INSTALL_BIN) ./files/usr/lib/mptcp-bonding/setup-bond.sh $(1)/usr/lib/mptcp-bonding/setup-bond.sh

	# sysupgrade: preserve config across firmware upgrades
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/mptcp-bonding $(1)/lib/upgrade/keep.d/mptcp-bonding
endef

$(eval $(call BuildPackage,mptcp-bonding))
