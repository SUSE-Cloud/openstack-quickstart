#!/bin/bash
#
# Initial data for Keystone using python-keystoneclient
#
# Tenant               User      Roles
# ------------------------------------------------------------------
# admin                admin     admin
# service              glance    admin
# service              nova      admin, [ResellerAdmin (swift only)]
# service              neutron   admin        # if enabled
# service              swift     admin        # if enabled
# service              cinder    admin        # if enabled
# service              heat      admin        # if enabled
# demo                 admin     admin
# demo                 demo      Member, anotherrole
# invisible_to_admin   demo      Member
# Tempest Only:
# alt_demo             alt_demo  Member
#
# Variables set before calling this script:
# SERVICE_TOKEN - aka admin_token in keystone.conf
# SERVICE_ENDPOINT - local Keystone admin endpoint
# SERVICE_TENANT_NAME - name of tenant containing service accounts
# SERVICE_HOST - host used for endpoint creation
# ENABLED_SERVICES - stack.sh's list of services to start
# DEVSTACK_DIR - Top-level DevStack directory
# KEYSTONE_CATALOG_BACKEND - used to determine service catalog creation

# Defaults
# --------

ADMIN_PASSWORD=${ADMIN_PASSWORD:-secrete}
SERVICE_PASSWORD=${SERVICE_PASSWORD:-$ADMIN_PASSWORD}
export SERVICE_TOKEN=$SERVICE_TOKEN
export SERVICE_ENDPOINT=$SERVICE_ENDPOINT
SERVICE_TENANT_NAME=${SERVICE_TENANT_NAME:-service}

# Needed to bootstrap keystone with openstack client
KEYSTONE_BOOTSTRAP_PARAMS=" --os-token $SERVICE_TOKEN --os-url $SERVICE_ENDPOINT"

# openstacl client command
openstack="openstack $KEYSTONE_BOOTSTRAP_PARAMS"

# Tenants
# -------

ADMIN_TENANT=$($openstack project create \
                         -c id -f value admin)
SERVICE_TENANT=$($openstack project create \
                           -c id -f value $SERVICE_TENANT_NAME)
DEMO_TENANT=$($openstack project create \
                        -c id -f value demo)
INVIS_TENANT=$($openstack project create \
                         -c id -f value invisible_to_admin)


# Users
# -----

ADMIN_USER=$($openstack user create -c id -f value \
                                         --password="$ADMIN_PASSWORD" \
                                         --email=admin@example.com \
                                         admin)
DEMO_USER=$($openstack user create -c id -f value \
                                        --password="$ADMIN_PASSWORD" \
                                        --email=admin@example.com \
                                        demo)


# Roles
# -----

ADMIN_ROLE=$($openstack role create -c id -f value admin)
# ANOTHER_ROLE demonstrates that an arbitrary role may be created and used
# TODO(sleepsonthefloor): show how this can be used for rbac in the future!
ANOTHER_ROLE=$($openstack role create -c id -f value anotherrole)


# Add Roles to Users in Tenants
$openstack role add --user $ADMIN_USER \
          --project $ADMIN_TENANT $ADMIN_ROLE
$openstack role add --user $ADMIN_USER \
          --project $DEMO_TENANT $ADMIN_ROLE
$openstack role add --user $DEMO_USER \
          --project $DEMO_TENANT $ANOTHER_ROLE


# The Member role is used by Horizon and Swift so we need to keep it:
MEMBER_ROLE=$($openstack role create -c id -f value Member)
$openstack role add --user $DEMO_USER --project $DEMO_TENANT $MEMBER_ROLE
$openstack role add --user $DEMO_USER --project $INVIS_TENANT $MEMBER_ROLE


# Services
# --------

# Keystone
if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
	KEYSTONE_SERVICE=$($openstack service create -c id -f value \
		--type=identity \
		--description="Keystone Identity Service" \
                keystone)
	$openstack endpoint create \
	    --region RegionOne \
		--publicurl "http://$SERVICE_HOST:\$(public_port)s/v2.0" \
		--adminurl "http://$SERVICE_HOST:\$(admin_port)s/v2.0" \
		--internalurl "http://$SERVICE_HOST:\$(public_port)s/v2.0" \
                $KEYSTONE_SERVICE
fi

# Nova
if [[ "$ENABLED_SERVICES" =~ "n-cpu" ]]; then
    NOVA_USER=$($openstack user create -c id -f value \
        --password="$SERVICE_PASSWORD" \
        --project $SERVICE_TENANT \
        --email=nova@example.com \
        nova)
    $openstack role add \
        --project $SERVICE_TENANT \
        --user $NOVA_USER \
        $ADMIN_ROLE
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        NOVA_SERVICE=$($openstack service create -c id -f value \
            --type=compute \
            --description="Nova Compute Service" \
            nova)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:8774/v2/\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:8774/v2/\$(tenant_id)s" \
            --internalurl "http://$SERVICE_HOST:8774/v2/\$(tenant_id)s" \
            $NOVA_SERVICE

        # Create Nova V2.1 Services
        NOVA_V21_SERVICE=$($openstack service create -c id -f value \
            --type=compute \
            --description="Nova Compute Service V2.1" \
            nova)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s" \
            --internalurl "http://$SERVICE_HOST:8774/v2.1/\$(tenant_id)s" \
            $NOVA_V21_SERVICE
    fi

    # Nova needs ResellerAdmin role to download images when accessing
    # swift through the s3 api. The admin role in swift allows a user
    # to act as an admin for their tenant, but ResellerAdmin is needed
    # for a user to act as any tenant. The name of this role is also
    # configurable in swift-proxy.conf
    RESELLER_ROLE=$($openstack role create -c id -f value ResellerAdmin)
    $openstack role add --user $NOVA_USER --project $SERVICE_TENANT $RESELLER_ROLE
fi

# Heat
if [[ "$ENABLED_SERVICES" =~ "heat" ]]; then
    HEAT_API_CFN_PORT=${HEAT_API_CFN_PORT:-8000}
    HEAT_API_PORT=${HEAT_API_PORT:-8004}

    HEAT_USER=$($openstack user create -c id -f value \
                          --password="$SERVICE_PASSWORD" \
                          --project $SERVICE_TENANT \
                          --email=heat@example.com \
                          heat)
    $openstack role add --user $HEAT_USER --project $SERVICE_TENANT $ADMIN_ROLE

    # heat_stack_user role is for users created by Heat
    STACK_USER_ROLE=$($openstack role create -c id -f value heat_stack_user)

    # heat_stack_owner role is given to users who create Heat Stacks
    STACK_OWNER_ROLE=$($openstack role create -c id -f value heat_stack_owner)

    # Give the role to the demo and admin users so they can create stacks
    # in either of the projects created by devstack
    $openstack role add --user $DEMO_USER --project $DEMO_TENANT $STACK_OWNER_ROLE
    $openstack role add --user $ADMIN_USER --project $DEMO_TENANT $STACK_OWNER_ROLE
    $openstack role add --user $ADMIN_USER --project $ADMIN_TENANT $STACK_OWNER_ROLE

    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        HEAT_CFN_SERVICE=$($openstack service create -c id -f value \
            --type=cloudformation \
            --description="Heat CloudFormation Service" \
            heat-cfn)

        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1" \
            --adminurl "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1" \
            --internalurl "http://$SERVICE_HOST:$HEAT_API_CFN_PORT/v1" \
            $HEAT_CFN_SERVICE

        HEAT_SERVICE=$($openstack service create -c id -f value \
            --type=orchestration \
            --description="Heat Service" \
            heat)

        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s" \
            --internalurl "http://$SERVICE_HOST:$HEAT_API_PORT/v1/\$(tenant_id)s" \
            $HEAT_SERVICE
    fi
fi

# Glance
if [[ "$ENABLED_SERVICES" =~ "g-api" ]]; then
    GLANCE_USER=$($openstack user create -c id -f value \
        --password="$SERVICE_PASSWORD" \
        --project $SERVICE_TENANT \
        --email=glance@example.com \
        glance)
    $openstack role add --user $GLANCE_USER --project $SERVICE_TENANT $ADMIN_ROLE

    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        GLANCE_SERVICE=$($openstack service create -c id -f value \
            --type=image \
            --description="Glance Image Service" \
            glance)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:9292" \
            --adminurl "http://$SERVICE_HOST:9292" \
            --internalurl "http://$SERVICE_HOST:9292" \
            $GLANCE_SERVICE
    fi
fi

# Swift
if [[ "$ENABLED_SERVICES" =~ "swift" ]]; then
    SWIFT_USER=$($openstack user create -c id -f value \
        --password="$SERVICE_PASSWORD" \
        --project $SERVICE_TENANT \
        --email=swift@example.com \
        swift)
    $openstack role add --user $SWIFT_USER --project $SERVICE_TENANT $ADMIN_ROLE

    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        SWIFT_SERVICE=$($openstack service create -c id -f value \
            --type="object-store" \
            --description="Swift Service" \
            swift)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:8080" \
            --internalurl "http://$SERVICE_HOST:8080/v1/AUTH_\$(tenant_id)s" \
            $SWIFT_SERVICE
    fi
fi

if [[ "$ENABLED_SERVICES" =~ "q-svc" ]]; then
    NEUTRON_USER=$($openstack user create -c id -f value \
        --password="$SERVICE_PASSWORD" \
        --project $SERVICE_TENANT \
        --email=neutron@example.com \
        neutron)
    $openstack role add --user $NEUTRON_USER --project $SERVICE_TENANT $ADMIN_ROLE

    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        NEUTRON_SERVICE=$($openstack service create -c id -f value \
            --type=network \
            --description="Quantum Service" \
            neutron)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:9696/" \
            --adminurl "http://$SERVICE_HOST:9696/" \
            --internalurl "http://$SERVICE_HOST:9696/" \
            $NEUTRON_SERVICE
    fi
fi

# EC2
if [[ "$ENABLED_SERVICES" =~ "n-api" ]]; then
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        EC2_SERVICE=$($openstack service create -c id -f value \
            --type=ec2 \
            --description="EC2 Compatibility Layer" \
            ec2)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:8773/services/Cloud" \
            --adminurl "http://$SERVICE_HOST:8773/services/Admin" \
            --internalurl "http://$SERVICE_HOST:8773/services/Cloud" \
            $EC2_SERVICE
    fi
fi

# S3
if [[ "$ENABLED_SERVICES" =~ "n-obj" || "$ENABLED_SERVICES" =~ "swift" ]]; then
    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        S3_SERVICE=$($openstack service create -c id -f value \
            --type=s3 \
            --description="S3" \
            s3)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:$S3_SERVICE_PORT" \
            --adminurl "http://$SERVICE_HOST:$S3_SERVICE_PORT" \
            --internalurl "http://$SERVICE_HOST:$S3_SERVICE_PORT" \
            $S3_SERVICE
    fi
fi

if [[ "$ENABLED_SERVICES" =~ "tempest" ]]; then
    # Tempest has some tests that validate various authorization checks
    # between two regular users in separate tenants
    ALT_DEMO_TENANT=$($openstack project create -c id -f value \
                             alt_demo)
    ALT_DEMO_USER=$($openstack user create -c id -f value \
        --password="$ADMIN_PASSWORD" \
        --email=alt_demo@example.com \
        alt_demo)
    $openstack role add --user $ALT_DEMO_USER --project $ALT_DEMO_TENANT $MEMBER_ROLE
fi

if [[ "$ENABLED_SERVICES" =~ "c-api" ]]; then
    CINDER_USER=$($openstack user create -c id -f value \
                                              --password="$SERVICE_PASSWORD" \
                                              --project $SERVICE_TENANT \
                                              --email=cinder@example.com \
                                              cinder)
    $openstack role add --user $CINDER_USER --project $SERVICE_TENANT $ADMIN_ROLE

    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        CINDER_SERVICE=$($openstack service create -c id -f value \
            --type=volume \
            --description="Cinder Service" \
            cinder)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s" \
            --adminurl "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s" \
            --internalurl "http://$SERVICE_HOST:8776/v1/\$(tenant_id)s" \
            $CINDER_SERVICE


        # Create Cinder V2 API
        CINDER_V2_SERVICE=$($openstack service create -f value -c id \
                        --type=volumev2 \
                        --description="Cinder Volume Service V2" \
                        cinderv2)
        $openstack endpoint create \
                        --region RegionOne \
                        --publicurl "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s" \
                        --adminurl "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s" \
                        --internalurl "http://$SERVICE_HOST:8776/v2/\$(tenant_id)s" \
                         $CINDER_V2_SERVICE
    fi
fi

# Ceilometer
if [[ "$ENABLED_SERVICES" =~ "ceilometer-api" ]]; then
    CEILOMETER_SERVICE_PROTOCOL=http
    CEILOMETER_SERVICE_HOST=$SERVICE_HOST
    CEILOMETER_SERVICE_PORT=${CEILOMETER_SERVICE_PORT:-8777}

    CEILOMETER_USER=$($openstack user create -c id -f value \
        --password="$SERVICE_PASSWORD" \
        --project $SERVICE_TENANT \
        --email=ceilometer@example.com \
        ceilometer)
    $openstack role add --user $CEILOMETER_USER --project $SERVICE_TENANT $ADMIN_ROLE

    if [[ "$KEYSTONE_CATALOG_BACKEND" = 'sql' ]]; then
        CEILOMETER_SERVICE=$($openstack service create -c id -f value \
            --type=metering \
            --description="Openstack Telemetry Service" \
            ceilometer)
        $openstack endpoint create \
            --region RegionOne \
            --publicurl "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/" \
            --adminurl "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/" \
            --internalurl "$CEILOMETER_SERVICE_PROTOCOL://$CEILOMETER_SERVICE_HOST:$CEILOMETER_SERVICE_PORT/" \
            $CEILOMETER_SERVICE
    fi
fi

# Manila
if [[ "$ENABLED_SERVICES" =~ "m-api" ]]; then
    MANILA_SERVICE_PROTOCOL=http
    MANILA_SERVICE_HOST=$SERVICE_HOST
    MANILA_SERVICE_PORT=${MANILA_SERVICE_PORT:-8786}
    MANILA_USER=$($openstack user create \
                             --password="$SERVICE_PASSWORD" \
                             --project=$SERVICE_TENANT \
                             --email=manila@example.com \
                             manila \
                             -f value -c id)
    $openstack role add \
               --project $SERVICE_TENANT \
               --user $MANILA_USER \
               $ADMIN_ROLE
    # manila v1 api
    MANILA_SERVICE=$($openstack service create \
                                --type=share \
                                --description="Manila Shared Filesystem Service" \
                                manila -f value -c id)
    $openstack endpoint create \
               --region RegionOne \
               --publicurl "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v1/\$(tenant_id)s" \
               --adminurl "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v1/\$(tenant_id)s" \
               --internalurl "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v1/\$(tenant_id)s" \
               $MANILA_SERVICE

    # manila v2 api (added during Liberty)
    MANILA_SERVICE_V2=$($openstack service create \
                                   --type=sharev2 \
                                   --description="Manila Shared Filesystem Service V2" \
                                   manilav2 -f value -c id)
    $openstack endpoint create \
               --region RegionOne \
               --publicurl "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v2/\$(tenant_id)s" \
               --adminurl "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v2/\$(tenant_id)s" \
               --internalurl "$MANILA_SERVICE_PROTOCOL://$MANILA_SERVICE_HOST:$MANILA_SERVICE_PORT/v2/\$(tenant_id)s" \
               $MANILA_SERVICE_V2
fi
