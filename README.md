openstack-quickstart
====================

Scripts and configs to easily generate an OpenStack demo setup. You should not run these
on a production machine because they heavily modify your system, use a VM if in doubt.

To deploy a single node cloud it is sufficient to run:

  /usr/sbin/openstack-quickstart-demosetup

Additionally, you can deploy further compute nodes by invoking (on a different machine / VM):

  /usr/sbin/openstack-quickstart-extranodesetup

