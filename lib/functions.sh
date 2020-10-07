#!/bin/bash

SERVICE_HOST=$IP
ADMIN_PASSWORD=$pw

KEYSTONE_AUTH_HOST=${KEYSTONE_AUTH_HOST:-$SERVICE_HOST}
KEYSTONE_AUTH_PORT=${KEYSTONE_AUTH_PORT:-35357}
KEYSTONE_SERVICE_PORT=${KEYSTONE_AUTH_SERVICE_PORT:-5000}
KEYSTONE_AUTH_PROTOCOL=${KEYSTONE_AUTH_PROTOCOL:-http}
KEYSTONE_PUBLIC_ENDPOINT=$KEYSTONE_AUTH_PROTOCOL://$KEYSTONE_AUTH_HOST:$KEYSTONE_SERVICE_PORT/v2.0
KEYSTONE_PUBLIC_ENDPOINT_V3=$KEYSTONE_AUTH_PROTOCOL://$KEYSTONE_AUTH_HOST:$KEYSTONE_SERVICE_PORT/v3

function install_packages {
    test $# -gt 0 || return
    rpm -q $* > /dev/null || zypper -n in $* || exit 1
}

function run_as {
    test $# -eq 2 || (echo "Bad usage of run_as function. Arguments: $*"; exit 1)
    su - $1 -s /bin/bash -c "$2"
}

function get_service_tenant_id {
    openstack project show service -c id -f value
}

function start_and_enable_service {
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
        if [[ $(systemctl cat $s 2>/dev/null| wc -l) -gt 0 ]]; then
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

function stop_and_disable_service {
    i=/etc/init.d/$1
    if [ -x $i ] ; then
        $i stop
    elif [ -n "$(type -p systemctl)" ]; then
        s=${1}.service
        if [[ $(systemctl cat $s 2>/dev/null| wc -l) -gt 0 ]]; then
            systemctl stop $s || :
            systemctl disable $s || :
        fi
    fi
    chkconfig -d $1
}

function get_ext_bridge_name {
    local id
    id=`openstack network show -f value -c id ext`
    echo "brq"${id:0:11}
}


function get_ext_bridge_ip {
    local gateway_ip
    gateway_ip=`openstack subnet show -f value -c gateway_ip ext`
    echo $gateway_ip
}

function get_ext_bridge_ip_prefix {
    local cidr
    cidr=`openstack subnet show -f value -c cidr ext`
    echo $cidr | cut -f2 -d/
}

function get_ext_bridge_cidr {
    openstack subnet show -f value -c cidr ext
}

function setup_ext_bridge_on_boot {
    local eth

    eth=$FLOATING_ETH
    [ x$FLOATING_VLAN != x ] && eth+=".$FLOATING_VLAN"

    cat >/etc/sysconfig/network/ifcfg-$1 <<EOF
BRIDGE='yes'
BRIDGE_FORWARDDELAY='0'
BRIDGE_STP='off'
IPADDR='$2'
STARTMODE='onboot'
USERCONTROL='no'
POST_UP_SCRIPT='wicked:openstack-quickstart-neutron-$1'
EOF
    cat >/etc/sysconfig/network/scripts/openstack-quickstart-neutron-$1<<EOF
iptables -t nat -A POSTROUTING -s $3 -o $eth -j MASQUERADE
EOF
    chmod 755 /etc/sysconfig/network/scripts/openstack-quickstart-neutron-$1
    iptables -t nat -L POSTROUTING | grep -q MASQUERADE || /etc/sysconfig/network/scripts/openstack-quickstart-neutron-$1
}


function setup_node_for_nova_compute {
    # change libvirt to run qemu as user qemu
    sed -i -e 's;.*user.*=.*;user = "qemu";' /etc/libvirt/qemu.conf
    if [ -e /dev/kvm ]; then
        chown root:kvm /dev/kvm
        chmod 660 /dev/kvm
    fi

    crudini --set /etc/libvirt/libvirtd.conf "" listen_tcp 1
    crudini --set /etc/libvirt/libvirtd.conf "" listen_tls 0
    crudini --set /etc/libvirt/libvirtd.conf "" auth_tcp '"none"'
    #crudini --set /etc/libvirt/libvirtd.conf "" listen_addr $MY_ADMINIP

    grep -q -e vmx -e svm /proc/cpuinfo || MODE=qemu
    # use lxc or qemu, if kvm is unavailable
    if rpm -q openstack-nova-compute >/dev/null ; then
        if [ "$MODE" = lxc ] ; then
            crudini --set /etc/nova/nova.conf libvirt virt_type lxc
            install_packages lxc
        elif [ "$MODE" = qemu ] ; then
            crudini --set /etc/nova/nova.conf libvirt virt_type qemu
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

function setup_nova_compute {
    local c=/etc/nova/nova.conf.d/100-nova.conf
    crudini --set $c DEFAULT linuxnet_interface_driver ""
    crudini --set $c DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
    crudini --set $c DEFAULT allow_resize_to_same_host True

    if grep -q vmx /proc/cpuinfo; then
        crudini --set $c libvirt cpu_mode custom
        crudini --set $c libvirt cpu_model "SandyBridge"
    fi
}

function disable_firewall_and_enable_forwarding {

    # disable firewall before playing with ip_forward stuff
    rm -f /usr/lib/python*/site-packages/nova-iptables.lock.lock # workaround bug
    rm -f /var/lock/SuSEfirewall2.booting # workaround openSUSE bug
    if test -e /sbin/SuSEfirewall2; then
        SuSEfirewall2 stop        # interferes with openstack's network/firewall
        stop_and_disable_service SuSEfirewall2_setup
        stop_and_disable_service SuSEfirewall2_init
    fi

    # activate ip-forwarding
    cat - > /etc/sysctl.d/90-openstack-quickstart.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
# do we need this?
#net.ipv4.conf.all.proxy_arp = 1

    sysctl -p /etc/sysctl.d/90-openstack-quickstart.conf
}

function setup_messaging_client {
    local conf=$1
    local ip=$2
    local pw=$3
    [ -e "$conf" ] || return 0

    crudini --set $conf DEFAULT transport_url rabbit://openstack:$pw@$ip
}

# see also devstack/keystone configure_auth_token_middleware()
function setup_keystone_authtoken {
    local conf=$1
    local admin_user=$2
    local admin_password=$3
    local section=${4:-keystone_authtoken}

    crudini --set $conf $section auth_type password
    crudini --set $conf $section username $admin_user
    crudini --set $conf $section password $admin_password
    crudini --set $conf $section user_domain_name Default
    crudini --set $conf $section project_name service
    crudini --set $conf $section project_domain_name Default
    crudini --set $conf $section auth_url http://$IP:5000/
    #crudini --set $conf $section signing_dir $signing_dir
}

#################################################
# common functions from devstack/functions-common
#################################################

# Grab a numbered field from python prettytable output
# Fields are numbered starting with 1
# Reverse syntax is supported: -1 is the last field, -2 is second to last, etc.
# get_field field-number
function get_field {
    local data field
    while read data; do
        if [ "$1" -lt 0 ]; then
            field="(\$(NF$1))"
        else
            field="\$$(($1 + 1))"
        fi
        echo "$data" | awk -F'[ \t]*\\|[ \t]*' "{print $field}"
    done
}

# Gets or creates a domain
# Usage: get_or_create_domain <name> <description>
function get_or_create_domain {
    local domain_id
    # Gets domain id
    domain_id=$(
        # Gets domain id
        openstack domain show $1 \
            -f value -c id 2>/dev/null ||
        # Creates new domain
        openstack domain create $1 \
            --description "$2" \
            -f value -c id
    )
    echo $domain_id
}

# Gets or creates group
# Usage: get_or_create_group <groupname> <domain> [<description>]
function get_or_create_group {
    local desc="${3:-}"
    local group_id
    # Gets group id
    group_id=$(
        # Creates new group with --or-show
        openstack group create $1 \
            --domain $2 --description "$desc" --or-show \
            -f value -c id
    )
    echo $group_id
}

# Gets or creates user
# Usage: get_or_create_user <username> <password> <domain> [<email>]
function get_or_create_user {
    local user_id
    if [[ ! -z "$4" ]]; then
        local email="--email=$4"
    else
        local email=""
    fi
    # Gets user id
    user_id=$(
        # Creates new user with --or-show
        openstack user create \
            $1 \
            --password "$2" \
            --domain=$3 \
            $email \
            --or-show \
            -f value -c id
    )
    echo $user_id
}

# Gets or creates project
# Usage: get_or_create_project <name> <domain>
function get_or_create_project {
    local project_id
    project_id=$(
        # Creates new project with --or-show
        openstack project create $1 \
            --domain=$2 \
            --or-show -f value -c id
    )
    echo $project_id
}

# Gets or creates role
# Usage: get_or_create_role <name>
function get_or_create_role {
    local role_id
    role_id=$(
        # Creates role with --or-show
        openstack role create $1 \
            --or-show -f value -c id
    )
    echo $role_id
}

# Returns the domain parts of a function call if present
# Usage: _get_domain_args [<user_domain> <project_domain>]
function _get_domain_args {
    local domain
    domain=""

    if [[ -n "$1" ]]; then
        domain="$domain --user-domain $1"
    fi
    if [[ -n "$2" ]]; then
        domain="$domain --project-domain $2"
    fi

    echo $domain
}

# Gets or adds user role to project
# Usage: get_or_add_user_project_role <role> <user> <project> [<user_domain> <project_domain>]
function get_or_add_user_project_role {
    local user_role_id

    domain_args=$(_get_domain_args $4 $5)

    # Gets user role id
    user_role_id=$(openstack role assignment list \
        --role $1 \
        --user $2 \
        --project $3 \
        $domain_args \
        | grep '^|\s[a-f0-9]\+' | get_field 1)
    if [[ -z "$user_role_id" ]]; then
        # Adds role to user and get it
        openstack role add $1 \
            --user $2 \
            --project $3 \
            $domain_args
        user_role_id=$(openstack role assignment list \
            --role $1 \
            --user $2 \
            --project $3 \
            $domain_args \
            | grep '^|\s[a-f0-9]\+' | get_field 1)
    fi
    echo $user_role_id
}

# Gets or adds user role to domain
# Usage: get_or_add_user_domain_role <role> <user> <domain>
function get_or_add_user_domain_role {
    local user_role_id
    # Gets user role id
    user_role_id=$(openstack role assignment list \
        --role $1 \
        --user $2 \
        --domain $3 \
        | grep '^|\s[a-f0-9]\+' | get_field 1)
    if [[ -z "$user_role_id" ]]; then
        # Adds role to user and get it
        openstack role add $1 \
            --user $2 \
            --domain $3
        user_role_id=$(openstack role assignment list \
            --role $1 \
            --user $2 \
            --domain $3 \
            | grep '^|\s[a-f0-9]\+' | get_field 1)
    fi
    echo $user_role_id
}

# Gets or adds group role to project
# Usage: get_or_add_group_project_role <role> <group> <project>
function get_or_add_group_project_role {
    local group_role_id
    # Gets group role id
    group_role_id=$(openstack role assignment list \
        --role $1 \
        --group $2 \
        --project $3 \
        -f value)
    if [[ -z "$group_role_id" ]]; then
        # Adds role to group and get it
        openstack role add $1 \
            --group $2 \
            --project $3
        group_role_id=$(openstack role assignment list \
            --role $1 \
            --group $2 \
            --project $3 \
            -f value)
    fi
    echo $group_role_id
}

# Gets or creates service
# Usage: get_or_create_service <name> <type> <description>
function get_or_create_service {
    local service_id
    # Gets service id
    service_id=$(
        # Gets service id
        openstack service show $2 -f value -c id 2>/dev/null ||
        # Creates new service if not exists
        openstack service create \
            $2 \
            --name $1 \
            --description="$3" \
            -f value -c id
    )
    echo $service_id
}

# Create an endpoint with a specific interface
# Usage: _get_or_create_endpoint_with_interface <service> <interface> <url> <region>
function _get_or_create_endpoint_with_interface {
    local endpoint_id
    endpoint_id=$(openstack endpoint list \
        --service $1 \
        --interface $2 \
        --region $4 \
        -c ID -f value)
    if [[ -z "$endpoint_id" ]]; then
        # Creates new endpoint
        endpoint_id=$(openstack endpoint create \
            $1 $2 $3 --region $4 -f value -c id)
    fi

    echo $endpoint_id
}

# Gets or creates endpoint
# Usage: get_or_create_endpoint <service> <region> <publicurl> [adminurl] [internalurl]
function get_or_create_endpoint {
    # NOTE(jamielennnox): when converting to v3 endpoint creation we go from
    # creating one endpoint with multiple urls to multiple endpoints each with
    # a different interface.  To maintain the existing function interface we
    # create 3 endpoints and return the id of the public one. In reality
    # returning the public id will not make a lot of difference as there are no
    # scenarios currently that use the returned id. Ideally this behaviour
    # should be pushed out to the service setups and let them create the
    # endpoints they need.
    local public_id
    public_id=$(_get_or_create_endpoint_with_interface $1 public $3 $2)
    # only create admin/internal urls if provided content for them
    if [[ -n "$4" ]]; then
        _get_or_create_endpoint_with_interface $1 admin $4 $2
    fi
    if [[ -n "$5" ]]; then
        _get_or_create_endpoint_with_interface $1 internal $5 $2
    fi
    # return the public id to indicate success, and this is the endpoint most likely wanted
    echo $public_id
}
