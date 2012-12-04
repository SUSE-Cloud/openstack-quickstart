PREFIX=/usr
BINDIR=${PREFIX}/bin
SBINDIR=${PREFIX}/sbin
LIBEXECDIR=${PREFIX}/lib
SYSCONFDIR=/etc

install:
	install -d ${DESTDIR}${SBINDIR}
	install -p -m 755 scripts/openstack-quickstart-demosetup ${DESTDIR}${SBINDIR}
	install -p -m 755 scripts/openstack-quickstart-democleanup ${DESTDIR}${SBINDIR}
	install -p -m 755 scripts/openstack-quickstart-extranodesetup ${DESTDIR}${SBINDIR}
	install -p -m 755 scripts/openstack-loopback-lvm ${DESTDIR}${SBINDIR}
	install -d ${DESTDIR}${BINDIR}
	install -p -m 755 scripts/getkstoken ${DESTDIR}${BINDIR}
	install -d ${DESTDIR}${LIBEXECDIR}/devstack
	install -p -m 755 scripts/keystone_data.sh ${DESTDIR}${LIBEXECDIR}/devstack
	install -d ${DESTDIR}${SYSCONFDIR}
	install -p -m 644 etc/bash.openstackrc ${DESTDIR}${SYSCONFDIR}
	install -p -m 600 etc/openstackquickstartrc ${DESTDIR}${SYSCONFDIR}
