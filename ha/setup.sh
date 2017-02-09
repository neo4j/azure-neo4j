#!/bin/bash
# Environment parameters:
#    HEAP_SIZE           fraction of RAM used by the JVM heap         (optional)
#    NEO4J_PASSWORD      password                                     (optional)
#    NEO4J_VERSION       version of Neo4j to install                  (optional)
#    SSL_KEY             SSL Private key to use for HTTPS             (optional)
#    SSL_CERT            SSL Certificate to use for HTTPS             (optional)
#    HTTP_PORT           the port for HTTP access                     (optional)
#    HTTPS_PORT          the port for HTTPS access                    (optional)
#    BOLT_PORT           the port for BOLT access                     (optional)
#    HTTP_LOGGING        'true' to enable http logging                (optional)
#    JOIN_TIMEOUT        how long to (re-)try to join the cluster     (optional)
#    COORD_PORT          port to use for Neo4j HA communication       (HA, optional)
#    DATA_PORT           port to use for Neo4j HA communication       (HA, optional)
#    MY_ID               identifier of this instance in the cluster   (HA)
#    MY_IP               ip address of this instance                  (HA)
#    HOST_IPS            ip addresses of all instances in the cluster (HA)

# Memory sizes: HEAP_MEMORY, PAGE_MEMORY - computed from HEAP_SIZE and RAM_MEMORY - all *_MEMORY variables are in kiB
RAM_MEMORY=$(cat /proc/meminfo | grep ^MemTotal | sed -e 's/: */ /g' | cut -d\  -f2)
# Reserve 2G for OS
RAM_MEMORY=$(expr $RAM_MEMORY - 2097152)
case "${HEAP_SIZE: -1}" in
    g|G)
        HEAP_SIZE="${HEAP_SIZE%?}"
        if [ -n "$HEAP_SIZE" -a "$HEAP_SIZE" -gt 0 ]; then
            HEAP_MEMORY=$(expr "$HEAP_SIZE" \* 1024 \* 1024)
        else
            HEAP_MEMORY=""
        fi
    ;;
    m|M)
        HEAP_SIZE="${HEAP_SIZE%?}"
        if [ -n "$HEAP_SIZE" -a "$HEAP_SIZE" -gt 0 ]; then
            HEAP_MEMORY=$(expr "$HEAP_SIZE" \* 1024)
        else
            HEAP_MEMORY=""
        fi
    ;;
    k|K)
        HEAP_SIZE="${HEAP_SIZE%?}"
        if [ -n "$HEAP_SIZE" -a "$HEAP_SIZE" -gt 0 ]; then
            HEAP_MEMORY="$HEAP_SIZE"
        else
            HEAP_MEMORY=""
        fi
    ;;
    \%)
        HEAP_SIZE="${HEAP_SIZE%?}"
        if [ -n "$HEAP_SIZE" -a "$HEAP_SIZE" -gt 0 -a "$HEAP_SIZE" -lt 100 ]; then
            # Memory percentage given
            HEAP_MEMORY=$(expr $RAM_MEMORY \* $HEAP_SIZE / 100)
        else
            HEAP_MEMORY=""
        fi
    ;;
    *)
        HEAP_MEMORY=""
    ;;
esac
if [ -z "$HEAP_MEMORY" ]; then
    # Memory size not specified (or invalid) - used 2/5 of RAM
    HEAP_MEMORY=$(expr $RAM_MEMORY \* 2 / 5)
fi
# Must leave some memory for Lucene. And memory has a tendency to consume more actual RAM.
# TODO This calculation should be more precise
PAGE_MEMORY=$(expr $RAM_MEMORY - 3 / 2 \* $HEAP_MEMORY)
echo HEAP_MEMORY=${HEAP_MEMORY}k
echo PAGE_MEMORY=${PAGE_MEMORY}k

# (Default value for) COORD_PORT
if [ -z "$COORD_PORT" ]; then
    COORD_PORT=5001
fi
# (Default value for) DATA_PORT
if [ -z "$DATA_PORT" ]; then
    DATA_PORT=6001
fi

# (Default value for) HTTP_PORT
if [ -z "$HTTP_PORT" ]; then
    HTTP_PORT=7474
fi
# (Default value for) HTTPS_PORT
if [ -z "$HTTPS_PORT" ]; then
    HTTPS_PORT=7473
fi
# (Default value for) BOLT_PORT
if [ -z "$BOLT_PORT" ]; then
    BOLT_PORT=7687
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

configure_ssl()
{
  # Write user defined SSL certificates
  if [ -n "${SSL_CERT}" ] && [ -n "${SSL_KEY}" ]; then
    mkdir -p /var/lib/neo4j/certificates
    echo "${SSL_CERT}" > /var/lib/neo4j/certificates/neo4j.cert
    echo "${SSL_KEY}" > /var/lib/neo4j/certificates/neo4j.key
    chown --recursive neo4j: /var/lib/neo4j/certificates/*
    chmod 600 /var/lib/neo4j/certificates/*
  fi
}

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
        setting dbms.memory.heap.initial_size "$(expr $HEAP_MEMORY / 1024)" neo4j.conf
        setting dbms.memory.heap.max_size "$(expr $HEAP_MEMORY / 1024)" neo4j.conf
        setting dbms.memory.pagecache.size "${PAGE_MEMORY}k"
    fi

    setting dbms.connector.bolt.type BOLT
    setting dbms.connector.bolt.enabled true
    setting dbms.connector.bolt.address "0.0.0.0:${BOLT_PORT}"

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

    if [ -n "$JOIN_TIMEOUT" ]; then
        setting ha.join_timeout "$JOIN_TIMEOUT"
    fi
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
configure_ssl
configure_neo4j
systemctl start neo4j
set_neo4j_password
