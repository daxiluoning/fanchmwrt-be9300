include $(TOPDIR)/rules.mk

PKG_NAME:=be9300-defaults
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKGARCH:=all
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=FanchmWrt-BE9300 build

include $(INCLUDE_DIR)/package.mk

define Package/be9300-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=GL-BE9300 defaults for OpenAppFilter
  DEPENDS:=+appfilter
endef

define Package/be9300-defaults/description
  Board-specific defaults for running OpenAppFilter on the GL.iNet
  GL-BE9300 (Flint 3): installs /etc/config/fwx with disable_hnat=1 and
  disables firewall4 software/hardware flow offloading on first boot so
  that the DPI engine sees every forwarded packet.
endef

define Package/be9300-defaults/conffiles
/etc/config/fwx
endef

# Files-only package: there is no ./src to copy, so override the default
# Build/Prepare (which would run `cp ./src/* ...` and fail).
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

# No compilation step either: the default would run make in an empty dir.
define Build/Compile
endef

define Package/be9300-defaults/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_CONF) ./files/fwx $(1)/etc/config/fwx
	$(INSTALL_BIN) ./files/99-be9300-oaf $(1)/etc/uci-defaults/99-be9300-oaf
endef

$(eval $(call BuildPackage,be9300-defaults))
