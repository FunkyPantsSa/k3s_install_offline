#!/bin/bash

# --- helper functions for logs ---
info() {
  echo -e '\033[32m[INFO]\033[0m ' "$@"
}
warn() {
  echo -e '\033[31m[warn]\033[0m ' "$@" >&2
}
fatal() {
  echo -e '\033[41;5m[ERROR]\033[0m ' "$@" >&2
  exit 1
}
# 创建nvidia-container-runtime及k3s-gpu-share支持

gpu_support_k3s() {

  tar zxf tools/nvidia-airgap.tgz -C /

  mkdir /etc/kubernetes /etc/nvidia-container-runtime -p
  cat >/etc/kubernetes/scheduler-policy-config.json <<-EOF
{
  "kind": "Policy",
  "apiVersion": "v1",
  "extenders": [
    {
      "urlPrefix": "http://127.0.0.1:32766/gpushare-scheduler",
      "filterVerb": "filter",
      "bindVerb":   "bind",
      "enableHttps": false,
      "nodeCacheCapable": true,
      "managedResources": [
        {
          "name": "aliyun.com/gpu-mem",
          "ignoredByScheduler": false
        }
      ],
      "ignorable": false
    }
  ]
}
EOF

  # nvidia-container-runtime所需配置

  cat >/etc/nvidia-container-runtime/config.toml <<-EOF
disable-require = false
#swarm-resource = "DOCKER_RESOURCE_GPU"
#accept-nvidia-visible-devices-envvar-when-unprivileged = true
#accept-nvidia-visible-devices-as-volume-mounts = false

[nvidia-container-cli]
#root = "/run/nvidia/driver"
#path = "/usr/bin/nvidia-container-cli"
environment = []
#debug = "/var/log/nvidia-container-toolkit.log"
#ldcache = "/etc/ld.so.cache"
load-kmods = true
#no-cgroups = false
#user = "root:video"
ldconfig = "@/sbin/ldconfig.real"

[nvidia-container-runtime]
#debug = "/var/log/nvidia-container-runtime.log"
EOF

  cat >/etc/docker/daemon.json <<-EOF
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
"data-root": "/data/var/lib/docker",
"default-runtime": "nvidia",
"runtimes": {
    "nvidia": { 
	"path": "/usr/bin/nvidia-container-runtime", 
	"runtimeArgs": []
    }   
}
}
EOF
  sed -i '/^\s*$/d' $SYSTEMFILE_PATH
  #sed -i '/^$/d' $SYSTEMFILE_PATH
  #sed -i '/^[[:space:]]*$/d' $SYSTEMFILE_PATH
  if [ "$(cat $SYSTEMFILE_PATH | grep "scheduler-policy-config" | wc -l)" == "0" ]; then
    echo "        '--kube-scheduler-arg=policy-config-file=/etc/kubernetes/scheduler-policy-config.json'  \\" >>$SYSTEMFILE_PATH
    echo "" >>$SYSTEMFILE_PATH
  fi
  systemctl daemon-reload

}

install_nvidia_support() {

  info "重启k3s环境。"

  if [ "agent" == "$GPU_S" ]; then
    SYSTEMFILE_PATH="/etc/systemd/system/k3s-agent.service"

    gpu_support_k3s
    systemctl stop k3s-agent.service
    systemctl restart docker
    systemctl start k3s-agent.service
    warn "需要添加该节点的gpu标签，例如："
    info "      kubectl label node $(hostname) gpushare=true"
  else
    SYSTEMFILE_PATH="/etc/systemd/system/k3s.service"
    cp tools/kubectl-inspect-gpushare /usr/bin/
    gpu_support_k3s
    systemctl stop k3s.service
    systemctl restart docker
    systemctl start k3s.service
    sleep 5
    kubectl apply -f manifests/gpushare-schd-extender.yaml
    kubectl apply -f manifests/gpushare-device-plugin.yaml
    kubectl apply -f manifests/nvidia-device-plugin.yaml
    info "添加标签：gpushare=true"
    kubectl label node $(hostname) gpushare=true
  fi

}

info "部署gpu支持组件。"
read -p "        worker节点请输入\"agent\"，为空则默认master节点：" GPU_S

info "添加gpu组件支持。"

install_nvidia_support

info "完成！"
