#!/bin/bash

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

# Usage: get_or_add_user_project_role <role> <user> <project>
function get_or_add_user_project_role {
    local user_role_id
    # Gets user role id
    user_role_id=$(openstack role list \
        --user $2 \
        --column "ID" \
        --project $3 \
        --column "Name" \
        | grep " $1 " | get_field 1)
    if [[ -z "$user_role_id" ]]; then
        # Adds role to user and get it
        openstack role add $1 \
            --user $2 \
            --project $3
        user_role_id=$(openstack role list \
            --user $2 \
            --column "ID" \
            --project $3 \
            --column "Name" \
            | grep " $1 " | get_field 1)
    fi
    echo $user_role_id
}

# Usage: get_or_add_user_domain_role <role> <user> <domain>
function get_or_add_user_domain_role {
    local user_role_id
    # Gets user role id
    user_role_id=$(openstack role list \
        --user $2 \
        --column "ID" \
        --domain $3 \
        --column "Name" \
        | grep " $1 " | get_field 1)
    if [[ -z "$user_role_id" ]]; then
        # Adds role to user and get it
        openstack role add $1 \
            --user $2 \
            --domain $3
        user_role_id=$(openstack role list \
            --user $2 \
            --column "ID" \
            --domain $3 \
            --column "Name" \
            | grep " $1 " | get_field 1)
    fi
    echo $user_role_id
}

# Usage: get_or_add_group_project_role <role> <group> <project>
function get_or_add_group_project_role {
    local group_role_id
    # Gets group role id
    group_role_id=$(openstack role list \
        --group $2 \
        --project $3 \
        -c "ID" -f value)
    if [[ -z "$group_role_id" ]]; then
        # Adds role to group and get it
        openstack role add $1 \
            --group $2 \
            --project $3
        group_role_id=$(openstack role list \
            --group $2 \
            --project $3 \
            -c "ID" -f value)
    fi
    echo $group_role_id
}

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

# Usage: get_or_create_endpoint <service> <region> <publicurl> <adminurl> <internalurl>
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
    _get_or_create_endpoint_with_interface $1 admin $4 $2
    _get_or_create_endpoint_with_interface $1 internal $5 $2

    # return the public id to indicate success, and this is the endpoint most likely wanted
    echo $public_id
}

#################################################
# functions from devstack lib/keystone
#################################################
# create_service_user <name> [role]
#
# The role defaults to the service role. It is allowed to be provided as optional as historically
# a lot of projects have configured themselves with the admin or other role here if they are
# using this user for other purposes beyond simply auth_token middleware.
function create_service_user {
    local role=${2:-service}

    local user
    user=$(get_or_create_user "$1" "$SERVICE_PASSWORD" default)
    get_or_add_user_project_role "$role" "$user" "$SERVICE_PROJECT_NAME"
}


#################################################
# functions from devstack lib/tempest
#################################################

# create_keystone_accounts() - Sets up common required keystone accounts

# Tenant               User       Roles
# ------------------------------------------------------------------
# admin                admin      admin
# service              --         --
# --                   --         service
# --                   --         ResellerAdmin
# --                   --         Member
# demo                 admin      admin
# demo                 demo       Member, anotherrole
# alt_demo             admin      admin
# alt_demo             alt_demo   Member, anotherrole
# invisible_to_admin   demo       Member

# Group                Users            Roles                 Tenant
# ------------------------------------------------------------------
# admins               admin            admin                 admin
# nonadmins            demo, alt_demo   Member, anotherrole   demo, alt_demo

# Migrated from keystone_data.sh
function create_keystone_accounts {

    # The keystone bootstrapping process (performed via keystone-manage bootstrap)
    # creates an admin user, admin role and admin project. As a sanity check
    # we exercise the CLI to retrieve the IDs for these values.
    local admin_tenant
    admin_tenant=$(openstack project show "admin" -f value -c id)
    local admin_user
    admin_user=$(openstack user show "admin" -f value -c id)
    local admin_role
    admin_role=$(openstack role show "admin" -f value -c id)

    get_or_add_user_domain_role $admin_role $admin_user default

    # Create service project/role
    get_or_create_project "$SERVICE_PROJECT_NAME" default

    # Service role, so service users do not have to be admins
    get_or_create_role service

    # The ResellerAdmin role is used by Nova and Ceilometer so we need to keep it.
    # The admin role in swift allows a user to act as an admin for their tenant,
    # but ResellerAdmin is needed for a user to act as any tenant. The name of this
    # role is also configurable in swift-proxy.conf
    get_or_create_role ResellerAdmin

    # The Member role is used by Horizon and Swift so we need to keep it:
    local member_role
    member_role=$(get_or_create_role "Member")

    # another_role demonstrates that an arbitrary role may be created and used
    # TODO(sleepsonthefloor): show how this can be used for rbac in the future!
    local another_role
    another_role=$(get_or_create_role "anotherrole")

    # invisible tenant - admin can't see this one
    local invis_tenant
    invis_tenant=$(get_or_create_project "invisible_to_admin" default)

    # demo
    local demo_tenant
    demo_tenant=$(get_or_create_project "demo" default)
    local demo_user
    demo_user=$(get_or_create_user "demo" \
        "$ADMIN_PASSWORD" "default" "demo@example.com")

    get_or_add_user_project_role $member_role $demo_user $demo_tenant
    get_or_add_user_project_role $admin_role $admin_user $demo_tenant
    get_or_add_user_project_role $another_role $demo_user $demo_tenant
    get_or_add_user_project_role $member_role $demo_user $invis_tenant

    # alt_demo
    local alt_demo_tenant
    alt_demo_tenant=$(get_or_create_project "alt_demo" default)
    local alt_demo_user
    alt_demo_user=$(get_or_create_user "alt_demo" \
        "$ADMIN_PASSWORD" "default" "alt_demo@example.com")

    get_or_add_user_project_role $member_role $alt_demo_user $alt_demo_tenant
    get_or_add_user_project_role $admin_role $admin_user $alt_demo_tenant
    get_or_add_user_project_role $another_role $alt_demo_user $alt_demo_tenant

    # groups
    local admin_group
    admin_group=$(get_or_create_group "admins" \
        "default" "openstack admin group")
    local non_admin_group
    non_admin_group=$(get_or_create_group "nonadmins" \
        "default" "non-admin group")

    get_or_add_group_project_role $member_role $non_admin_group $demo_tenant
    get_or_add_group_project_role $another_role $non_admin_group $demo_tenant
    get_or_add_group_project_role $member_role $non_admin_group $alt_demo_tenant
    get_or_add_group_project_role $another_role $non_admin_group $alt_demo_tenant
    get_or_add_group_project_role $admin_role $admin_group $admin_tenant
}

#################################################
# script starts here
#################################################

set -e

ADMIN_PASSWORD=${ADMIN_PASSWORD:-secrete}
SERVICE_PASSWORD=${SERVICE_PASSWORD:-$ADMIN_PASSWORD}
SERVICE_ENDPOINT=$SERVICE_ENDPOINT
SERVICE_TENANT_NAME=${SERVICE_TENANT_NAME:-service}
SERVICE_PROJECT_NAME=${SERVICE_TENANT_NAME:-service}

# bootstrap keystone (also creates endpoint and service in catalog)
keystone-manage bootstrap \
                --bootstrap-username admin \
                --bootstrap-password "$ADMIN_PASSWORD" \
                --bootstrap-project-name admin \
                --bootstrap-role-name admin \
                --bootstrap-service-name keystone \
                --bootstrap-region-id "RegionOne" \
                --bootstrap-admin-url "http://$SERVICE_HOST:\$(admin_port)s/v3" \
                --bootstrap-public-url "http://$SERVICE_HOST:\$(public_port)s/v3" \
                --bootstrap-internal-url "http://$SERVICE_HOST:\$(public_port)s/v3"

# Set up password auth credentials now that Keystone is bootstrapped
export OS_IDENTITY_API_VERSION=3
export OS_AUTH_URL=$SERVICE_ENDPOINT
export OS_USERNAME=admin
export OS_USER_DOMAIN_ID=default
export OS_PASSWORD=$ADMIN_PASSWORD
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_ID=default
export OS_REGION_NAME=RegionOne

create_keystone_accounts


# Nova
if [[ "$ENABLED_SERVICES" =~ "n-cpu" ]]; then
    create_service_user "nova" "admin"
    get_or_create_service "nova_legacy" "compute_legacy" "Nova Compute Service (Legacy 2.0)"
    get_or_create_endpoint \
        "compute_legacy" \
        "RegionOne" \
        "http://$SERVICE_HOST:8774/v2/\$(tenant_id)s" \
        "http://$SERVICE_HOST:8774/v2/\$(tenant_id)s" \
        "http://$SERVICE_HOST:8774/v2/\$(tenant_id)s"

    get_or_create_service "nova" "compute" "Nova Compute Service"
    get_or_create_endpoint \
        "compute" \
        "RegionOne" \
        "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s" \
        "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s" \
        "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s"

    # Nova needs ResellerAdmin role to download images when accessing
    # swift through the s3 api.
    get_or_add_user_project_role ResellerAdmin nova $SERVICE_PROJECT_NAME
fi

# Heat
if [[ "$ENABLED_SERVICES" =~ "heat" ]]; then
    HEAT_API_CFN_PORT=${HEAT_API_CFN_PORT:-8000}
    HEAT_API_PORT=${HEAT_API_PORT:-8004}

    create_service_user "heat" "admin"
    # heat_stack_user role is for users created by Heat
    get_or_create_role "heat_stack_user"

    get_or_create_service "heat" "orchestration" "Heat Orchestration Service"
    get_or_create_endpoint \
        "orchestration" \
        "RegionOne" \
        "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s" \
        "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s" \
        "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s"

    get_or_create_service "heat-cfn" "cloudformation" "Heat CloudFormation Service"
    get_or_create_endpoint \
        "cloudformation"  \
        "RegionOne" \
        "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1" \
        "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1" \
        "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1"
fi

# Glance
if [[ "$ENABLED_SERVICES" =~ "g-api" ]]; then
    create_service_user "glance"
    # required for swift access
    glance_swift_user=$(get_or_create_user "glance-swift" \
                                           "$SERVICE_PASSWORD" "default" "glance-swift@example.com")
    get_or_add_user_project_role "ResellerAdmin" $glance_swift_user $SERVICE_PROJECT_NAME

    get_or_create_service "glance" "image" "Glance Image Service"
    get_or_create_endpoint \
        "image" \
        "RegionOne" \
        "http://$SERVICE_HOST:9292" \
        "http://$SERVICE_HOST:9292" \
        "http://$SERVICE_HOST:9292"

    if [[ "$ENABLED_SERVICES" =~ "g-glare" ]]; then
        create_service_user "glare"
        get_or_create_service "glare" "artifact" "Glance Artifact Service"
        get_or_create_endpoint \
            "artifact" \
            "RegionOne" \
            "http://$SERVICE_HOST:9494" \
            "http://$SERVICE_HOST:9494" \
            "http://$SERVICE_HOST:9494"
    fi
fi

# Swift
if [[ "$ENABLED_SERVICES" =~ "swift" ]]; then
    # NOTE(jroll): Swift doesn't need the admin role here, however Ironic uses
    # temp urls, which break when uploaded by a non-admin role
    create_service_user "swift" "admin"

    get_or_create_service "swift" "object-store" "Swift Service"
    get_or_create_endpoint \
        "object-store" \
        "RegionOne" \
        "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s" \
        "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s" \
        "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s"
fi

if [[ "$ENABLED_SERVICES" =~ "q-svc" ]]; then
    create_service_user "neutron" "admin"

    get_or_create_service "neutron" "network" "Neutron Service"
    get_or_create_endpoint \
        "network" \
        "RegionOne" \
        "http://$SERVICE_HOST:9696/" \
        "http://$SERVICE_HOST:9696/" \
        "http://$SERVICE_HOST:9696/"
fi

# EC2
if [[ "$ENABLED_SERVICES" =~ "n-api" ]]; then
    create_service_user "ec2api" "admin"

    get_or_create_service "ec2" "ec2" "EC2 Compatibility Layer"
    get_or_create_endpoint \
        "ec2" \
        "RegionOne" \
        "http://$SERVICE_HOST:8773/" \
        "http://$SERVICE_HOST:8773/" \
        "http://$SERVICE_HOST:8773/"
fi

# S3
if [[ "$ENABLED_SERVICES" =~ "n-obj" || "$ENABLED_SERVICES" =~ "swift" ]]; then
    get_or_create_service "s3" "s3" "S3"
    get_or_create_endpoint \
        "s3" \
        "RegionOne" \
        "http://$SERVICE_HOST:3334/" \
        "http://$SERVICE_HOST:3334/" \
        "http://$SERVICE_HOST:3334/"
fi

if [[ "$ENABLED_SERVICES" =~ "c-api" ]]; then
    create_service_user "cinder"

    get_or_create_service "cinder" "volume" "Cinder Volume Service"
    get_or_create_endpoint \
        "volume" \
        "RegionOne" \
        "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s" \
        "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s" \
        "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s"

    get_or_create_service "cinderv2" "volumev2" "Cinder Volume Service V2"
    get_or_create_endpoint \
        "volumev2" \
        "RegionOne" \
        "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s" \
        "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s" \
        "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s"
fi

# Ceilometer
if [[ "$ENABLED_SERVICES" =~ "ceilometer-api" ]]; then
    CEILOMETER_SERVICE_PROTOCOL=http
    CEILOMETER_SERVICE_HOST=$SERVICE_HOST
    CEILOMETER_SERVICE_PORT=${CEILOMETER_SERVICE_PORT:-8777}

    create_service_user "ceilometer" "admin"

    get_or_create_service "ceilometer" "metering" "OpenStack Telemetry Service"
    get_or_create_endpoint \
        "metering" \
        "RegionOne" \
        "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/" \
        "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/" \
        "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/"
fi

# Manila
if [[ "$ENABLED_SERVICES" =~ "m-api" ]]; then
    MANILA_SERVICE_PROTOCOL=http
    MANILA_SERVICE_HOST=$SERVICE_HOST
    MANILA_SERVICE_PORT=${MANILA_SERVICE_PORT:-8786}

    create_service_user "manila"

    get_or_create_service "manila" "share" "Manila Shared Filesystem Service"
    get_or_create_endpoint \
        "share" \
        "RegionOne" \
        "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v1/\$(tenant_id)s" \
        "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v1/\$(tenant_id)s" \
        "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v1/\$(tenant_id)s"

    get_or_create_service "manilav2" "sharev2" "Manila Shared Filesystem Service V2"
    get_or_create_endpoint \
        "sharev2" \
        "RegionOne" \
        "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v2/\$(tenant_id)s" \
        "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v2/\$(tenant_id)s" \
        "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v2/\$(tenant_id)s"
fi
