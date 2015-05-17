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

