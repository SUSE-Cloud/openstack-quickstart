#!/bin/bash

function install_packages () {
    test $# -gt 0 || return
    rpm -q $* > /dev/null || zypper -n in $* || exit 1
}

function run_as () {
    test $# -eq 2 || (echo "Bad usage of run_as function. Arguments: $*"; exit 1)
    su - $1 -s /bin/bash -c "$2"
}

function get_router_id () {
    eval `neutron router-show -f shell -F id public`
    echo $id
}

function get_service_tenant_id () {
    id=`keystone tenant-get service | awk '/id/  { print $4 } '`

    echo $id
}

function start_and_enable_service () {
    i=/etc/init.d/$1
    if [ -x $i ] ; then
        insserv $1
        $i start
        $i status
        if [ $? -eq 3 ]; then
            echo "Service $1 is not running"
            exit 1
        fi
    elif [ -n "$(type -p systemctl)" ]; then
        s=${1}.service
        if [ $(systemctl cat $s 2>/dev/null| wc -l) -gt 0 ]; then
            systemctl enable $s
            systemctl start $s
            systemctl is-active --quiet $s
            if [ $? -eq 3 ]; then
                systemctl status $s || :
                journalctl -xn || :
                echo "Service $1 is not running"
                exit 1
            fi
        fi
    fi
}

function stop_and_disable_service () {
    i=/etc/init.d/$1
    if [ -x $i ] ; then
        $i stop
    fi
    chkconfig -d $1
}

function get_ext_bridge_name () {
    local id
    eval `neutron net-show -f shell -F id ext`
    echo "brq"${id:0:11}
}


function get_ext_bridge_ip () {
    local gateway_ip
    eval `neutron subnet-show -f shell -F gateway_ip ext`
    echo $gateway_ip
}

function get_ext_bridge_ip_prefix () {
    local cidr
    eval `neutron subnet-show -f shell -F cidr ext`
    echo $cidr | cut -f2 -d/
}

function get_ext_bridge_cidr () {
    local cidr
    eval `neutron subnet-show -f shell -F cidr ext`
    echo $cidr
}

function setup_ext_bridge_on_boot () {
    cat >/etc/sysconfig/network/ifcfg-$1 <<EOF
BRIDGE='yes'
BRIDGE_FORWARDDELAY='0'
BRIDGE_STP='off'
IPADDR='$2'
STARTMODE='onboot'
USERCONTROL='no'
POST_UP_SCRIPT='openstack-quickstart-neutron-$1'
EOF
    cat >/etc/sysconfig/network/scripts/openstack-quickstart-neutron-$1<<EOF
iptables -t nat -A POSTROUTING -s $3 -o $br -j MASQUERADE
EOF
    chmod 755 /etc/sysconfig/network/scripts/openstack-quickstart-neutron-$1
    iptables -t nat -L POSTROUTING | grep -q MASQERADE || /etc/sysconfig/network/scripts/openstack-quickstart-neutron-$1
}


function setup_node_for_nova_compute() {
    # change libvirt to run qemu as user qemu
    sed -i -e 's;.*user.*=.*;user = "qemu";' /etc/libvirt/qemu.conf
    if [ -e /dev/kvm ]; then
        chown root:kvm /dev/kvm
        chmod 660 /dev/kvm
    fi

    crudini --set /etc/libvirt/libvirtd.conf "" listen_tcp 1
    crudini --set /etc/libvirt/libvirtd.conf "" listen_addr $MY_ADMINIP
    crudini --set /etc/libvirt/libvirtd.conf "" listen_auth_tcp none

    grep -q -e vmx -e svm /proc/cpuinfo || MODE=lxc
    # use lxc or qemu, if kvm is unavailable
    if rpm -q openstack-nova-compute >/dev/null ; then
        if [ "$MODE" = lxc ] ; then
            crudini --set /etc/nova/nova.conf libvirt virt_type lxc
            install_packages lxc
        else
            grep -qw vmx /proc/cpuinfo && {
                modprobe kvm-intel
                echo kvm-intel > /etc/modules-load.d/openstack-kvm.conf
            }
            grep -qw svm /proc/cpuinfo && {
                modprobe kvm-amd
                echo kvm-amd > /etc/modules-load.d/openstack-kvm.conf
            }
        fi
        modprobe nbd
        modprobe vhost-net
        echo nbd > /etc/modules-load.d/openstack-quickstart-nova-compute.conf
        echo vhost-net >> /etc/modules-load.d/openstack-quickstart-nova-compute.conf
    fi

    start_and_enable_service libvirtd
}

