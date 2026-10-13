# SPDX-License-Identifier: GPL-3.0-only
#
# tollgate-wrt — Cashu-powered WiFi payment gateway for OpenWrt.
#
# This feed package downloads the upstream source tarball and builds it with
# golang-package.mk. The upstream repo (tollgate-module-basic-go) is NOT
# modified — its Go source lives under src/ and uses a multi-module layout
# (the main module at src/ plus sibling sub-modules wired via `replace`).
#
# The runtime files (init.d, uci-defaults, nftables.d, hotplug.d, man pages,
# captive-portal site, usr/bin helpers, keep.d) are NOT vendored into this
# feed. They are installed directly from the SOURCE TARBALL's packaging/files/
# directory (see $(PKG_TARBALL_DIR) below), which ships OpenWrt-shaped files
# because upstream releases its own .ipk from the same tree. Bumping
# PKG_SOURCE_VERSION pulls in the matching runtime files automatically — there
# is no separate files/ tree to keep in sync.
#
# Versioning: PKG_VERSION (apk-legal, underscore) names the package version
# while PKG_SOURCE_VERSION (hyphen, upstream git tag) drives the download
# URL/tarball name and the tag-named build dirs below — see the version block
# for why the two are split.
#
# One package, two binaries:
#   - tollgate-wrt : the service, the module-root main package at src/main.go
#   - tollgate      : the CLI, a SEPARATE module at src/cmd/tollgate-cli/
#
# Because the CLI is its own Go module it cannot share the main module's
# golang-package.mk build context, so Build/Compile builds the service via the
# default helper and then builds the CLI manually from its own module dir,
# reusing the framework's exported cross-compile/toolchain environment.

include $(TOPDIR)/rules.mk

PKG_NAME:=tollgate-wrt
# PKG_VERSION is the apk-legal package version. Since OpenWrt SDKs moved to
# apk (CONFIG_USE_APK, v24.10+), include/package-pack.mk feeds
# "version:$(VERSION)" = "$(PKG_VERSION)-r$(PKG_RELEASE)" to `apk mkpkg`, and
# apk-tools 3.x REJECTS hyphens ("package version is invalid", make Error 99).
# apk pre-release convention uses '_' (or '~'): 0.6.0_alpha1-r1 is accepted.
PKG_VERSION:=0.6.0_alpha1
# PKG_SOURCE_VERSION is the upstream git tag (hyphenated, immutable on GitHub).
# It drives ONLY the download naming/URL and the tag-named build dirs below —
# never the package version — so the two can differ legally.
PKG_SOURCE_VERSION:=0.6.0-alpha1
PKG_RELEASE:=1

PKG_SOURCE:=tollgate-module-basic-go-$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/OpenTollGate/tollgate-module-basic-go/tar.gz/v$(PKG_SOURCE_VERSION)?
PKG_HASH:=c0ca1b37cbccde8e46de8e42287185d322c648bb10ad317b3e496a136a0e35f7

PKG_MAINTAINER:=Felix <felix@tollgate.me>
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE

# PKG_BUILD_DIR points at the tarball's src/ directory: that is where the main
# module's go.mod lives, so golang-package.mk operates on the module root and
# the `replace ./xxx` directives resolve to sibling directories in the tree.
# It stays tag-named (PKG_SOURCE_VERSION, hyphen) because the tarball extracts
# to tollgate-module-basic-go-0.6.0-alpha1/ — it must NOT follow PKG_VERSION.
PKG_BUILD_DIR:=$(BUILD_DIR)/tollgate-module-basic-go-$(PKG_SOURCE_VERSION)/src

# PKG_TARBALL_DIR is the tarball extraction root (parent of PKG_BUILD_DIR).
# Build/Prepare extracts the WHOLE upstream tarball there, so packaging/files/
# — the OpenWrt-shaped runtime files — survives as a sibling of src/ and can
# be referenced by the install recipe below. Nothing is vendored into this
# feed; the files ride along with the upstream release tarball. Tag-named for
# the same reason as PKG_BUILD_DIR (see above).
PKG_TARBALL_DIR:=$(BUILD_DIR)/tollgate-module-basic-go-$(PKG_SOURCE_VERSION)

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/OpenTollGate/tollgate-module-basic-go
# The service is the module-root main package (src/main.go). Building it pulls
# in every sub-module via the main go.mod's replace graph.
GO_PKG_BUILD_PKG:=$(GO_PKG)

# Version injection. src/cli is its own sub-module, so the import path keeps
# the /src segment (matches how upstream's CI injects these values). Tied to
# PKG_SOURCE_VERSION so the baked-in Version/GitCommit match the upstream tag
# (v0.6.0-alpha1 / 0.6.0-alpha1) rather than the apk-legal package version.
GO_PKG_LDFLAGS_X:= \
	$(GO_PKG)/src/cli.Version=v$(PKG_SOURCE_VERSION) \
	$(GO_PKG)/src/cli.GitCommit=$(PKG_SOURCE_VERSION) \
	$(GO_PKG)/src/cli.BuildTime=$(SOURCE_DATE_EPOCH)

# NOTE on the golang-package.mk include path:
#   As a standalone src-git feed, the golang helpers live in the consumer's
#   installed `packages` feed, so we anchor at $(TOPDIR)/feeds/packages/... .
#   When this directory is lifted into openwrt/packages as an upstream PR,
#   swap this single line for:
#     include ../../lang/golang/golang-package.mk
include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/tollgate-wrt
	SECTION:=net
	CATEGORY:=Network
	SUBMENU:=Captive Portals
	TITLE:=TollGate - Cashu-powered WiFi Payment Gateway
	URL:=https://tollgate.me
	DEPENDS:=+nodogsplash +jq $(GO_ARCH_DEPENDS)
endef

define Package/tollgate-wrt/description
	TollGate turns an OpenWrt router into a Cashu-powered payment gateway
	for internet access. Customers pay in sats (time- or data-based); the
	router gates network access via NoDogSplash and sweeps balances to
	configured Lightning addresses.
endef

define Package/tollgate-wrt/conffiles
/etc/tollgate/config.json
/etc/tollgate/install.json
/etc/tollgate/identities.json
/etc/nftables.d/20-nds-enforce.nft
endef

# Deterministic extraction + layout diagnostic. Upstream's go.mod lives in a
# tarball subdirectory (src/), and golang-package.mk expects go.mod at
# $(PKG_BUILD_DIR)/go.mod. Extract to $(BUILD_DIR) so $(PKG_BUILD_DIR) (the
# src/ subdir) is reliably populated, and print the layout so CI logs show
# whether the go.mod-not-found issue is extraction or deeper in golang-build.sh.
#
# NOTE: use `-xf <file>` explicitly, NOT `$(TAR_OPTIONS)`. OpenWrt defines
# TAR_OPTIONS:=-xf -` (read archive from stdin), which only works when the
# archive is piped in. Here the archive is a downloaded file in $(DL_DIR), so
# we must name it directly on the command line.
define Build/Prepare
	mkdir -p $(BUILD_DIR)
	$(TAR) -C $(BUILD_DIR) -xf $(DL_DIR)/$(PKG_SOURCE)
	$(Build/Patch)
	@echo "=== PKG_BUILD_DIR = $(PKG_BUILD_DIR) ==="
	@ls -la $(PKG_BUILD_DIR)
	@test -f $(PKG_BUILD_DIR)/go.mod && echo "go.mod: OK" || { echo "go.mod: MISSING"; exit 1; }
endef

# Build both binaries: the service via the framework helper, then the CLI from
# its separate module directory.
#
# WHY this override is REQUIRED (not stylistic): the CLI is its own Go module
# (`module tollgate-cli`, go.mod at src/cmd/tollgate-cli/go.mod), SEPARATE from
# the main module golang-package.mk operates on. GO_PKG_BUILD_PKG cannot cross
# module boundaries — the framework's Build/Compile runs `go install` inside the
# CURRENT module (src/), so it can only build packages in the main module
# (github.com/OpenTollGate/tollgate-module-basic-go); pointing GO_PKG_BUILD_PKG
# at the CLI's import path would fail. Hence the CLI must be built manually
# from its own module dir, reusing the framework's exported cross-compile
# environment. Upstream PR #125 tried to avoid this by restructuring the Go
# source (src/ -> repo root) but was abandoned (~120 files, never rebased), so
# this override is the supported way to ship both binaries from one package.
#
# Make runs each recipe line in a SEPARATE shell, so the cross-compile
# environment set up by GoPackage/Build/Compile does NOT carry over to the
# second recipe line. We must re-establish it via $(GO_PKG_VARS), which adds
# `go` to PATH and exports GOOS/GOARCH/GOARM/GOMIPS/CGO_ENABLED/CC/GOCACHE/
# GOMODCACHE — exactly what the framework uses. The -X ldflags are harmless
# no-ops for the CLI module (it does not contain those symbols).
define Build/Compile
	$(call GoPackage/Build/Compile)
	cd $(PKG_BUILD_DIR)/cmd/tollgate-cli && \
		$(GO_PKG_VARS) go build -trimpath \
			-ldflags "$(GO_PKG_LDFLAGS_X:%=-X %)" \
			-o $(GO_PKG_BUILD_BIN_DIR)/tollgate-cli .
endef

define Package/tollgate-wrt/preinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT:-}" ] && exit 0

# Record the install timestamp so the captive portal / wizard can show it.
if [ -f /etc/tollgate/install.json ]; then
	CURRENT_TIMESTAMP=$$(date +%s)
	if ! jq ".install_time = $$CURRENT_TIMESTAMP" /etc/tollgate/install.json > /tmp/install.json.tmp; then
		echo "Error: Failed to update install_time using jq" >&2
		exit 1
	fi
	if ! mv /tmp/install.json.tmp /etc/tollgate/install.json; then
		echo "Error: Failed to move temporary file to /etc/tollgate/install.json" >&2
		exit 1
	fi
else
	mkdir -p /etc/tollgate
	CURRENT_TIMESTAMP=$$(date +%s)
	if ! echo "{\"install_time\": $$CURRENT_TIMESTAMP}" > /etc/tollgate/install.json; then
		echo "Error: Failed to create /etc/tollgate/install.json" >&2
		exit 1
	fi
fi

exit 0
endef

define Package/tollgate-wrt/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT:-}" ] && exit 0

# Run the oneshot UCI defaults immediately so an install on a running router
# takes effect without waiting for the next boot, then enable the service.
for script in /etc/uci-defaults/90-tollgate-captive-portal-symlink \
              /etc/uci-defaults/99-tollgate-setup; do
	if [ -x "$$script" ]; then
		"$$script" || echo "Warning: $$script exited with code $$?" >&2
	fi
done

if [ -x /etc/init.d/tollgate-wrt ]; then
	/etc/init.d/tollgate-wrt enable 2>/dev/null || true
fi

exit 0
endef

# Runtime files are installed from the upstream source tarball's
# packaging/files/ directory (see PKG_TARBALL_DIR above), NOT from a vendored
# copy checked into this feed. The binaries install lines use
# $(GO_PKG_BUILD_BIN_DIR) and stay unchanged.
define Package/tollgate-wrt/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/tollgate-module-basic-go $(1)/usr/bin/tollgate-wrt
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/tollgate-cli $(1)/usr/bin/tollgate

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/etc/init.d/tollgate-wrt $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/etc/uci-defaults/90-tollgate-captive-portal-symlink $(1)/etc/uci-defaults/
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/etc/uci-defaults/99-tollgate-setup $(1)/etc/uci-defaults/

	$(INSTALL_DIR) $(1)/etc/nftables.d
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/etc/nftables.d/20-nds-enforce.nft $(1)/etc/nftables.d/
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/etc/nftables.d/30-backend-firewall.nft $(1)/etc/nftables.d/

	$(INSTALL_DIR) $(1)/usr/share/man/man8
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/man/man8/*.8 $(1)/usr/share/man/man8/

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/etc/hotplug.d/iface/95-tollgate-restart $(1)/etc/hotplug.d/iface/

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/usr/bin/check_package_path $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/usr/bin/tollgate-apply-ssl $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/usr/bin/tollgate-remove-ssl $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/usr/local/bin
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/usr/local/bin/first-login-setup $(1)/usr/local/bin/

	$(INSTALL_DIR) $(1)/etc/tollgate/ecash

	$(INSTALL_DIR) $(1)/etc/tollgate/tollgate-captive-portal-site
	$(CP) $(PKG_TARBALL_DIR)/packaging/files/tollgate-captive-portal-site/. $(1)/etc/tollgate/tollgate-captive-portal-site/

	$(INSTALL_DIR) $(1)/etc/crontabs

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/lib/upgrade/keep.d/tollgate $(1)/lib/upgrade/keep.d/
endef

$(eval $(call BuildPackage,tollgate-wrt))
