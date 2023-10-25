#!/bin/sh

data_path_dll=./tools
mkdir -p $data_path_dll


# --- helper functions for logs ---
info() {
    echo '\033[32m[INFO]\033[0m' "$@"
}
warn() {
    echo '\033[31m[WARN]\033[0m' "$@" >&2
}
fatal() {
    echo '\033[31m[FAIL]\033[0m' "$@" >&2
    exit 1
}


install_docker() {
    
    if [ "$(systemctl status docker >/dev/null 2>&1; echo $?)" != "0" ]; then
        iptables -F && iptables -X && iptables -F -t nat && iptables -X -t nat && iptables -F -t raw && iptables -X -t raw && iptables -F -t mangle && iptables -X -t mangle
        tar zxf $data_path_dll/docker-20.10.2.tgz -C /usr/local/bin/
        
        # docker systemd service
        cat >/etc/systemd/system/docker.service <<-EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io
[Service]
Environment="PATH=/usr/local/bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStart=/usr/local/bin/dockerd
ExecStartPost=/sbin/iptables -I FORWARD -s 0.0.0.0/0 -j ACCEPT
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
[Install]
WantedBy=multi-user.target
EOF
        
    fi
    
    mkdir /etc/docker/ -p && cat >/etc/docker/daemon.json <<-EOF
{
"registry-mirrors": [
    "https://wlzfs4t4.mirror.aliyuncs.com",
    "https://wlzfs4t4.mirror.aliyuncs.com"
],
"insecure-registries": [
    "dockerhub.private.rockcontrol.com:5000"
],
"bip":"169.254.31.1/24",
"max-concurrent-downloads": 10,
"log-driver": "json-file",
"log-level": "warn",
"log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
"data-root": "/data/var/lib/docker"
}
EOF
    
    
    
    # start docker service
    $(systemctl daemon-reload && systemctl enable docker && systemctl restart docker) || fatal "docker service restart failed!"
    for i in $(seq 9); do
        info "waiting docker service running..." && sleep 5
        docker_running=$(systemctl is-active docker)
        if [ $(systemctl is-active docker) == "active" ]; then
            info "docker service started success!" && break
            elif [ $i -eq 9 ]; then
            fatal "docker service started timeout! exit!"
        fi
    done
    
    
}

docker_check() {
    
    [ -f "$data_path_dll/docker-20.10.2.tgz" ] || curl -L https://ops-software.obs.cn-north-4.myhuaweicloud.com:443/dll/docker-20.10.2.tgz -o "$data_path_dll/docker-20.10.2.tgz"
    [ -f "$data_path_dll/docker-compose" ] || curl -L https://ops-software.obs.cn-north-4.myhuaweicloud.com:443/dll/docker-compose -o "$data_path_dll/docker-compose"
    
    
    if [ "$(docker version >/dev/null 2>&1; echo $?)" -eq 0 ]; then
        docker_version=$(docker version --format '{{.Server.Version}}')
        info "docker version: $docker_version"
        info "install docker-compose... "
        chmod +x $data_path_dll/docker-compose
        cp $data_path_dll/docker-compose /usr/local/bin/docker-compose
        
    else
        warn  "Failed to get Docker version"
        info  "install docker startting..."
        install_docker
    fi
}

$@