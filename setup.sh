#!/bin/bash
# Environment parameters:
#    HEAP_PERCENTAGE     fraction of RAM used by the JVM heap
#    [NEO4J_VERSION]     version of Neo4j to install                  (optional)
#    [COORD_PORT]        port to use for Neo4j HA communication       (HA, optional)
#    [DATA_PORT]         port to use for Neo4j HA communication       (HA, optional)
#    MY_ID               identifier of this instance in the cluster   (HA)
#    MY_IP               ip address of this instance                  (HA)
#    HOST_IPS            ip addresses of all instances in the cluster (HA)

# Memory sizes: HEAP_MEMORY, PAGE_MEMORY - computed from HEAP_PERCENTAGE
RAM_MEMORY=$(cat /proc/meminfo | grep ^MemTotal | sed -e 's/: */ /g' | cut -d\  -f2)
if [ -n "$HEAP_PERCENTAGE" -a "$HEAP_PERCENTAGE" -gt 0 -a "$HEAP_PERCENTAGE" -lt 100 ]; then
    # Memory percentage given
    HEAP_MEMORY=$(expr $RAM_MEMORY \* $HEAP_PERCENTAGE / 100)
else
    # Memory percentage not specified (or invalid)
    HEAP_MEMORY=$(expr $RAM_MEMORY \* 2 / 5)
fi
PAGE_MEMORY=$(expr $RAM_MEMORY - 2097152 - $HEAP_MEMORY)

# (Default value for) COORD_PORT
if [ -z "$COORD_PORT" ]; then
    COORD_PORT=5300
fi
# (Default value for) COORD_PORT
if [ -z "$DATA_PORT" ]; then
    DATA_PORT=$(expr $COORD_PORT + 1)
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

    sed -i -e "
        s/^#?dbms\.memory\.heap\.initial_size=.*$/dbms.memory.heap.initial_size=${HEAP_MEMORY}k/;
        s/^#?dbms\.memory\.heap\.max_size=.*$/dbms.memory.heap.max_size=${HEAP_MEMORY}k/;
    " /etc/neo4j/neo4j-wrapper.conf

    sed -i -e "
        s/^#?dbms\.memory\.pagecache\.size=.*$/dbms.memory.pagecache.size=${PAGE_MEMORY}k/;
        s/^#? ?dbms.connector.bolt.address=.*$/dbms.connector.bolt.address=0.0.0.0:7687/;
        s/^#? ?dbms.connector.https.address=.*$/dbms.connector.bolt.address=0.0.0.0:7474/;
        s/^dbms.connector.http.enabled=.*$/dbms.connector.http.enabled=false/;
    " /etc/neo4j/neo4j.conf

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

    sed -i -e "
        s/^#?dbms\.mode=.*$/dbms.mode=HA/;
        s/^#?ha\.server_id=.*$/ha.server_id=$MY_ID/;
        s/^#?ha\.initial_hosts=.*$/ha.initial_hosts=$HOST_PORTS/;
        s/^#?ha\.host\.data=.*$/ha.host.data=$MY_IP:$DATA_PORT/;
        s/^#?ha\.host\.coordination=.*$/ha.host.coordination=$MY_IP:$COORD_PORT/;
    " /etc/neo4j/neo4j.conf
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
    # parameters: -

    # create a script that automatically extends the VG
    cat >/var/lib/neo4j/lvm-extend.sh <<SCRIPT
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
    cat >/etc/udev/rules.d/91-neo4j-lvm-extend.rules <<RULES
# Rules for extending the neo4j lvm volume group on attach of new drive
ACTION=="add",SUBSYSTEM=="scsi",RUN+="/var/lib/neo4j/lvm-extend.sh"
RULES
}

install_neo4j
configure_lvm /dev/sdc
enable_lvm_autoextend
configure_neo4j
systemctl start neo4j
