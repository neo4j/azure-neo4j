#!/bin/bash
# Environment parameters:
#    HEAP_PERCENTAGE     fraction of RAM used by the JVM heap
#    NEO4J_PASSWORD      password
#    [NEO4J_VERSION]     version of Neo4j to install                  (optional)
#    HTTP_PORT           the port for HTTP access
#    HTTPS_PORT          the port for HTTPS access
#    HTTP_LOGGING        'true' to enable http logging
#    MASTER_BOLT_PORT    the port through which the master will accept bolt
#    SLAVE_BOLT_PORT     the port through which slaves will accept bolt
#    [COORD_PORT]        port to use for Neo4j HA communication       (HA, optional)
#    [DATA_PORT]         port to use for Neo4j HA communication       (HA, optional)
#    MY_ID               identifier of this instance in the cluster   (HA)
#    MY_IP               ip address of this instance                  (HA)
#    HOST_IPS            ip addresses of all instances in the cluster (HA)

# Memory sizes: HEAP_MEMORY, PAGE_MEMORY - computed from HEAP_PERCENTAGE
RAM_MEMORY=$(cat /proc/meminfo | grep ^MemTotal | sed -e 's/: */ /g' | cut -d\  -f2)
RAM_MEMORY=$(expr $RAM_MEMORY - 2097152)
if [ -n "$HEAP_PERCENTAGE" -a "$HEAP_PERCENTAGE" -gt 0 -a "$HEAP_PERCENTAGE" -lt 100 ]; then
    # Memory percentage given
    HEAP_MEMORY=$(expr $RAM_MEMORY \* $HEAP_PERCENTAGE / 100)
else
    # Memory percentage not specified (or invalid) - used 2/5 of RAM
    HEAP_MEMORY=$(expr $RAM_MEMORY \* 2 / 5)
fi
PAGE_MEMORY=$(expr $RAM_MEMORY - $HEAP_MEMORY)

# (Default value for) COORD_PORT
if [ -z "$COORD_PORT" ]; then
    COORD_PORT=5300
fi
# (Default value for) COORD_PORT
if [ -z "$DATA_PORT" ]; then
    DATA_PORT=$(expr $COORD_PORT + 1)
fi

# (Default value for) HTTP_PORT
if [ -z "$HTTP_PORT" ]; then
    HTTP_PORT=7474
fi
# (Default value for) HTTPS_PORT
if [ -z "$HTTPS_PORT" ]; then
    HTTPS_PORT=7473
fi
# (Default value for) MASTER_BOLT_PORT
if [ -z "$MASTER_BOLT_PORT" ]; then
    if [ -z "$SLAVE_BOLT_PORT" ]; then
        MASTER_BOLT_PORT=7687
    else
        MASTER_BOLT_PORT="$SLAVE_BOLT_PORT"
    fi
fi
# (Default value for) SLAVE_BOLT_PORT
if [ -z "$SLAVE_BOLT_PORT" ]; then
    SLAVE_BOLT_PORT="$MASTER_BOLT_PORT"
fi

if [ -z "$MY_IP" ]; then
    if [ -z "$HOST_IPS" ]; then
        MY_IP=$(ifconfig | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p')
        HOST_IPS=$MY_IP
    else
        echo HOST_IPS configured, but not MY_IP 1>&2
        exit 1
    fi
elif [ -z "$HOST_IPS" ]; then
    echo MY_IP configured, but not HOST_IPS 1>&2
    exit 1
fi


setting() {
    local setting="${1}"
    local value="${2}"
    local file="${3:-neo4j.conf}"

    if [ ! -f "/etc/neo4j/${file}" ]; then
        if [ -f "/etc/neo4j/neo4j.conf" ]; then
            file="neo4j.conf"
        fi
    fi

    if [ -n "${value}" ]; then
        if ! sed -i "/^ *#* *${setting//./\\.} *=.*$/{s//${setting}=${value}/;h}; $ {x;/./{x;q0};x;q1}" "/etc/neo4j/${file}"; then
            echo "${setting}=${value}" >>"/etc/neo4j/${file}"
        fi
    else
        # no value given, comment out the setting in the file (if present)
        sed -i "s/^\( *${setting//./\\.} *=.*\)/#\1/" "/etc/neo4j/${file}"
    fi
}


install_neo4j() {
    # Zulu deb sources
    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0x219BD9C9
    apt-add-repository 'deb http://repos.azulsystems.com/ubuntu stable main'
    # Neo4j deb sources
    wget -O - https://debian.neo4j.org/neotechnology.gpg.key | sudo apt-key add -
    echo 'deb http://debian.neo4j.org/repo stable/' > /etc/apt/sources.list.d/neo4j.list
    # Install
    apt update
    apt install -y zulu-8
    # Install Neo4j, "RUNLEVEL=1" means "don't start Neo4j after installation"
    if [ -z "$NEO4J_VERSION" -o "default" = "$NEO4J_VERSION" ]; then
        RUNLEVEL=1 apt install -y neo4j-enterprise
    else
        RUNLEVEL=1 apt install -y neo4j-enterprise=$NEO4J_VERSION
    fi
}

configure_neo4j() {
    # uses: PAGE_MEMORY, HEAP_MEMORY, MY_ID, MY_IP, HOST_IPS, DATA_PORT, COORD_PORT

    if [  "$RAM_MEMORY" -gt 0 ]; then
        setting dbms.memory.heap.initial_size "$(expr $HEAP_MEMORY / 1024)" neo4j-wrapper.conf
        setting dbms.memory.heap.max_size "$(expr $HEAP_MEMORY / 1024)" neo4j-wrapper.conf
        setting dbms.memory.pagecache.size "${PAGE_MEMORY}k"
    fi

    if [ "$MASTER_BOLT_PORT" = "$SLAVE_BOLT_PORT" ]; then
        setting dbms.connector.bolt.type    BOLT
        setting dbms.connector.bolt.enabled true
        setting dbms.connector.bolt.address "0.0.0.0:$MASTER_BOLT_PORT"
    else
        setting dbms.connector.bolt.type
        setting dbms.connector.bolt.enabled
        setting dbms.connector.bolt.address

        setting dbms.connector.master_bolt.type    BOLT
        setting dbms.connector.master_bolt.enabled true
        setting dbms.connector.master_bolt.address "0.0.0.0:$MASTER_BOLT_PORT"

        setting dbms.connector.slave_bolt.type    BOLT
        setting dbms.connector.slave_bolt.enabled true
        setting dbms.connector.slave_bolt.address "0.0.0.0:$SLAVE_BOLT_PORT"
    fi

    setting dbms.connector.https.type       HTTP
    setting dbms.connector.https.enabled    true
    setting dbms.connector.https.encryption TLS
    setting dbms.connector.https.address    "0.0.0.0:$HTTPS_PORT"

    setting dbms.connector.http.type    HTTP
    setting dbms.connector.http.enabled true
    setting dbms.connector.http.address "0.0.0.0:$HTTP_PORT"

    if [ "true" = "${HTTP_LOGGING}" ]; then
        setting dbms.logs.http.enabled true
    fi

    if [ "$MY_IP" != "$HOST_IPS" ]; then
        configure_ha
    fi
}

configure_ha() {
    # Configure Neo4j HA, uses: MY_ID, MY_IP, HOST_IPS, DATA_PORT, COORD_PORT
    local HOSTS=( ${HOST_IPS//,/ } )
    local HOST_PORTS=( "${HOSTS[@]/%/:$COORD_PORT}" )
    HOST_PORTS=$(printf ",%s" "${HOST_PORTS[@]}")
    HOST_PORTS=${HOST_PORTS:1}

    setting dbms.mode            HA
    setting ha.server_id         "$MY_ID"
    setting ha.initial_hosts     "$HOST_PORTS"
    setting ha.host.data         "$MY_IP:$DATA_PORT"
    setting ha.host.coordination "$MY_IP:$COORD_PORT"
    setting dbms.security.ha_status_auth_enabled false
}

set_neo4j_password() {
    # use curl to set the password (if given)
    if [ -n "$NEO4J_PASSWORD" ]; then
        local  end="$((SECONDS+100))"
        while true; do
            # Check if the password is set (and if the server is up)
            local http_code="$(curl --silent --write-out %{http_code} --user "neo4j:${NEO4J_PASSWORD}" --output /dev/null http://localhost:7474/db/data/ || true)"

            if [[ "${http_code}" = "200" ]]; then
                break;
            fi

            if [[ "${http_code}" = "401" ]]; then
                # Set the password (by authenticating using default password)
                curl --fail --silent --show-error --user neo4j:neo4j \
                     --data '{"password": "'"${NEO4J_PASSWORD}"'"}' \
                     --header 'Content-Type: application/json' \
                     http://localhost:7474/user/neo4j/password
                break;
            fi

            if [[ "${SECONDS}" -ge "${end}" ]]; then
                echo Failed to set neo4j password 1>&2
                exit 1
            fi

            sleep 1
        done
    fi
}

configure_lvm() {
    # parameters: <device-file>

    pvcreate $1
    vgcreate neo4j $1
    lvcreate -l 100%VG neo4j -n databases
    mkfs.ext4 /dev/neo4j/databases
    mount /dev/neo4j/databases /var/lib/neo4j/data/databases
    chown neo4j:adm /var/lib/neo4j/data/databases
}

enable_lvm_autoextend() {
    # create a script that automatically extends the VG
    cat >/var/lib/neo4j/lvm-extend.sh <<"SCRIPT"
#!/bin/sh
DEVFILE=/dev/$(ls /sys${DEVPATH}/block)
if [ -b "${DEVFILE}" ]; then
    pvcreate ${DEVFILE}
    vgextend neo4j ${DEVFILE}
    lvresize --resizefs -l 100%VG /dev/neo4j/databases
fi
SCRIPT
    chmod +x /var/lib/neo4j/lvm-extend.sh

    # Add udev rules for running the script on scsi attach
    cat >/etc/udev/rules.d/91-neo4j-lvm-extend.rules <<"RULES"
# Rules for extending the neo4j lvm volume group on attach of new drive
ACTION=="add",SUBSYSTEM=="scsi",RUN+="/var/lib/neo4j/lvm-extend.sh"
RULES
}

install_neo4j
systemctl stop neo4j
systemctl enable neo4j
configure_lvm /dev/sdc
enable_lvm_autoextend
configure_neo4j
systemctl start neo4j
set_neo4j_password
