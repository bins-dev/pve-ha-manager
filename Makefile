include /usr/share/dpkg/default.mk

PACKAGE=pve-ha-manager
SIMPACKAGE=pve-ha-simulator

GITVERSION:=$(shell git rev-parse HEAD)
BUILDDIR ?= $(PACKAGE)-$(DEB_VERSION)

DEB=$(PACKAGE)_$(DEB_VERSION)_$(DEB_HOST_ARCH).deb
DBG_DEB=$(PACKAGE)-dbgsym_$(DEB_VERSION)_$(DEB_HOST_ARCH).deb

DSC=$(PACKAGE)_$(DEB_VERSION).dsc
SIMDEB=$(SIMPACKAGE)_$(DEB_VERSION)_all.deb
SIMDSC=$(SIMPACKAGE)_$(DEB_VERSION).dsc

all: deb

.PHONY: tidy
tidy:
	git ls-files ':*.p[ml]'| xargs -n4 -P0 proxmox-perltidy
	cd src; proxmox-perltidy ha-manager pve-ha-crm pve-ha-lrm pve-ha-simulator pve-ha-tester

$(BUILDDIR):
	rm -rf $@ $@.tmp
	cp -a src/ $@.tmp
	cp -a debian $@.tmp/
	echo "git clone git://git.proxmox.com/git/pve-ha-manager.git\\ngit checkout $(GITVERSION)" > $@.tmp/debian/SOURCE
	mv $@.tmp $@

.PHONY: dinstall
dinstall: $(DEB) $(SIMDEB)
	dpkg -i $(DEB) $(SIMDEB)

.PHONY: deb
deb: $(DEB) $(SIMDEB)
$(DEB) $(DBG_DEB): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -b -us -uc
	lintian $(DEB)
	lintian $(SIMDEB)

.PHONY: dsc
dsc:
	$(MAKE) clean
	$(MAKE) $(DSC)
	lintian $(DSC)

$(DSC): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -S -us -uc -d

sbuild: $(DSC)
	sbuild $(DSC)

.PHONY: clean
clean:
	make -C src clean
	rm -rf $(PACKAGE)-[0-9]*/ *.dsc *.deb $(PACKAGE)*.tar* *.changes *.build *.buildinfo

.PHONY: distclean
distclean: clean

.PHONY: upload
upload: UPLOAD_DIST ?= $(DEB_DISTRIBUTION)
upload: $(DEB) $(SIMDEB)
	tar cf - $(DEB) $(DBG_DEB) $(SIMDEB)|ssh repoman@repo.proxmox.com -- upload --product pve --dist $(UPLOAD_DIST) --arch $(DEB_HOST_ARCH)
