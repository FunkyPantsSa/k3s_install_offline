#!/bin/bash
set -e
set -o noglob

. ./docker-install.sh


# --- helper functions for logs ---
info() {
    echo -e '\033[32m[INFO]\033[0m ' "$@"
}
warn() {
    echo -e '\033[31m[warn]\033[0m ' "$@" >&2
    WARN_IS=true

}
fatal() {
    echo -e '\033[41;5m[ERROR]\033[0m ' "$@" >&2
    exit 1
}

init_data() {

    GITHUB_URL=https://github.com/k3s-io/k3s/releases
    STORAGE_URL=https://storage.googleapis.com/k3s-ci-builds
    DOWNLOADER=

    INSTALL_K3S_SKIP_DOWNLOAD=true

    export K3S_TOKEN="k3sTokenClusterDeploy@1234567890"
    #MASTER附加配置
    INSTALL_K3S_MASTER_CONFIG="--disable=traefik --default-local-storage-path /data/local-path --write-kubeconfig /root/.kube/config --kube-apiserver-arg="authorization-mode=Node,RBAC" --kube-apiserver-arg="allow-privileged=true" --kube-apiserver-arg="service-node-port-range=20000-40000" "

    warn "本脚本功能仅支持使用该脚本部署的集群！"
    warn "本脚本功能仅支持使用该脚本部署的集群！"
    warn "本脚本功能仅支持使用该脚本部署的集群！"
    echo ""
    info "部署worker节点，需输入\"agent\"。"
    read -p "        部署高可用多master集群节点，需输入\"ha\"。为空默认部署单master：" MASTER_WORKER
    if [ "agent" == "$MASTER_WORKER" ]; then
        info "worker节点部署。"
        read -p "        输入现有master的ip：" MASTER_K3S_IP
        MASTER_WORKER_K3S=" agent "

        export K3S_URL=https://$MASTER_K3S_IP:6443

        info "确认master地址：K3S_URL=$K3S_URL"

    elif [ "ha" == "$MASTER_WORKER" ]; then

        info "高可用master节点部署。"

        info "增加高可用master节点，直接输入现有master节点ip。"

        read -p "        为空则默认初始化新高可用集群master：" MASTER_K3S_IP


        if [ $MASTER_K3S_IP ]; then
            MASTER_WORKER_K3S="server --server https://$MASTER_K3S_IP:6443 $INSTALL_K3S_MASTER_CONFIG "
            export K3S_URL=https://$MASTER_K3S_IP:6443
            info "确认master地址：K3S_URL=$K3S_URL"

        else
            MASTER_WORKER_K3S="server --cluster-init $INSTALL_K3S_MASTER_CONFIG "
            INIT_MIDDLEWARE=true
        fi
    else
        MASTER_WORKER_K3S="server $INSTALL_K3S_MASTER_CONFIG "
        INIT_MIDDLEWARE=true
    fi

    #INSTALL_K3S_EXEC="server --disable=traefik   --data-dir /data/rancher/k3s --write-kubeconfig /root/.kube/config  --docker --kube-apiserver-arg="authorization-mode=Node,RBAC" --kube-apiserver-arg="allow-privileged=true" --kube-proxy-arg "proxy-mode=ipvs" "masquerade-all=true" --kube-proxy-arg "metrics-bind-address=0.0.0.0" --kube-scheduler-arg="policy-config-file=/etc/kubernetes/scheduler-policy-config.json" --kube-apiserver-arg="service-node-port-range=20000-40000" --kubelet-arg="max-pods=500" "

    INSTALL_K3S_EXEC="$MASTER_WORKER_K3S   --data-dir /data/rancher/k3s --docker --kube-proxy-arg  "masquerade-all=true" --kube-proxy-arg "metrics-bind-address=0.0.0.0" --kubelet-arg="max-pods=110" "
    
}
#init_data
init_data
# --- deploy condition check ---
check_env() {
    uname -i | grep x86_64 >/dev/null 2>&1 && info "hardware platform check\033[32m[OK]\033[0m" || { fatal "hardware platform check\033[31m[failed]\033[0m (hardware platform must be x86_64)!"; }
    egrep 18.04 /etc/issue >/dev/null 2>&1 && info "system version check\033[32m[OK]\033[0m" || { warn "system version check\033[31m[failed]\033[0m (system version should be ubuntu 18.04)!"; }
    [ -d /data/ ] || warn "dir /data not exists! please mkdir or mount it! \033[31m[warn]\033[0m"
    nvidia-smi -L >/dev/null 2>&1 && info "nvidia gpu check\033[32m[OK]\033[0m" || { warn "nvidia gpu check\033[31m[failed]\033[0m (please check nvidia gpu driver or hardware)!"; }
    #ip a | grep br0 | grep inet >/dev/null 2>&1 && warn "br0 network check\033[32m[OK]\033[0m" || warn "br0 network check\033[31m[failed]\033[0m (network address shuould be set to br0)!"
    if [ $WARN_IS ]; then
        read -r -p "        Are You Continue? [quit for \"CTRL+C\" !] " Any_Input
    fi
}

prepare_images(){
    # prepare k3s cmd and airgap images.
    echo "[INFO] prepare k3s cmd and base images..."
    mkdir -p /var/lib/rancher/k3s/agent/images/ && cp ./images/k3s-airgap-images-amd64.tar /var/lib/rancher/k3s/agent/images/ -a && cp tools/k3s /usr/local/bin/ -a && chmod 755 /usr/local/bin/k3s
    docker load -i images/k3s-airgap-images-amd64.tar
    docker load -i images/base-images.tar
    echo "[INFO] prepare k3s cmd and base images success!"
}

# --- disable SELinux
Disable_SELinux() {

    if [ -f /etc/sysconfig/selinux ]; then
        info "SELinux_config is exist!"
        setenforce 0 && sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
        info "SELinux is Disable!"
    else
        warn "SELinux_config is not exist!"
    fi

}

# --- uninstall docker service ---
uninstall_docker() {
    echo "stoping docker service..."
    systemctl stop docker && systemctl disable docker
    echo "cleaning docker data..."
    rm /etc/docker -rf && rm /etc/systemd/system/docker.service -rf && rm /data/var/lib/docker -rf && rm /usr/local/bin/docker* -rf && rm /var/lib/dockershim -rf
    echo "uninstall docker success!"
}

# --- fatal if no systemd or openrc ---
verify_system() {
    if [ -x /sbin/openrc-run ]; then
        HAS_OPENRC=true
        return
    fi
    if [ -x /bin/systemctl ] || type systemctl >/dev/null 2>&1; then
        HAS_SYSTEMD=true
        return
    fi
    fatal 'Can not find systemd or openrc to use as a process supervisor for k3s'
}

# --- add quotes to command arguments ---
quote() {
    for arg in "$@"; do
        printf '%s\n' "$arg" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/'/"
    done
}

# --- add indentation and trailing slash to quoted args ---
quote_indent() {
    printf ' \\\n'
    for arg in "$@"; do
        printf '\t%s \\\n' "$(quote "$arg")"
    done
}

# --- escape most punctuation characters, except quotes, forward slash, and space ---
escape() {
    printf '%s' "$@" | sed -e 's/\([][!#$%&()*;<=>?\_`{|}]\)/\\\1/g;'
}

# --- escape double quotes ---
escape_dq() {
    printf '%s' "$@" | sed -e 's/"/\\"/g'
}

# --- ensures $K3S_URL is empty or begins with https://, exiting fatally otherwise ---
verify_k3s_url() {
    case "${K3S_URL}" in
    "") ;;

    https://*) ;;

    *)
        fatal "Only https:// URLs are supported for K3S_URL (have ${K3S_URL})"
        ;;
    esac
}

# --- define needed environment variables ---
setup_env() {
    # --- use command args if passed or create default ---
    case "$1" in
    # --- if we only have flags discover if command should be server or agent ---
    -* | "")
        if [ -z "${K3S_URL}" ]; then
            CMD_K3S=server
        else
            if [ -z "${K3S_TOKEN}" ] && [ -z "${K3S_TOKEN_FILE}" ] && [ -z "${K3S_CLUSTER_SECRET}" ]; then
                fatal "Defaulted k3s exec command to 'agent' because K3S_URL is defined, but K3S_TOKEN, K3S_TOKEN_FILE or K3S_CLUSTER_SECRET is not defined."
            fi
            CMD_K3S=agent
        fi
        ;;
        # --- command is provided ---
    *)
        CMD_K3S=$1
        shift
        ;;
    esac

    verify_k3s_url

    CMD_K3S_EXEC="${CMD_K3S}$(quote_indent "$@")"

    # --- use systemd name if defined or create default ---
    if [ -n "${INSTALL_K3S_NAME}" ]; then
        SYSTEM_NAME=k3s-${INSTALL_K3S_NAME}
    else
        if [ "${CMD_K3S}" = server ]; then
            SYSTEM_NAME=k3s
        else
            SYSTEM_NAME=k3s-${CMD_K3S}
        fi
    fi

    # --- check for invalid characters in system name ---
    valid_chars=$(printf '%s' "${SYSTEM_NAME}" | sed -e 's/[][!#$%&()*;<=>?\_`{|}/[:space:]]/^/g;')
    if [ "${SYSTEM_NAME}" != "${valid_chars}" ]; then
        invalid_chars=$(printf '%s' "${valid_chars}" | sed -e 's/[^^]/ /g')
        fatal "Invalid characters for system name:
            ${SYSTEM_NAME}
            ${invalid_chars}"
    fi

    # --- use sudo if we are not already root ---
    SUDO=sudo
    if [ $(id -u) -eq 0 ]; then
        SUDO=
    fi

    # --- use systemd type if defined or create default ---
    if [ -n "${INSTALL_K3S_TYPE}" ]; then
        SYSTEMD_TYPE=${INSTALL_K3S_TYPE}
    else
        if [ "${CMD_K3S}" = server ]; then
            SYSTEMD_TYPE=notify
        else
            SYSTEMD_TYPE=exec
        fi
    fi

    # --- use binary install directory if defined or create default ---
    if [ -n "${INSTALL_K3S_BIN_DIR}" ]; then
        BIN_DIR=${INSTALL_K3S_BIN_DIR}
    else
        # --- use /usr/local/bin if root can write to it, otherwise use /opt/bin if it exists
        BIN_DIR=/usr/local/bin
        if ! $SUDO sh -c "touch ${BIN_DIR}/k3s-ro-test && rm -rf ${BIN_DIR}/k3s-ro-test"; then
            if [ -d /opt/bin ]; then
                BIN_DIR=/opt/bin
            fi
        fi
    fi

    # --- use systemd directory if defined or create default ---
    if [ -n "${INSTALL_K3S_SYSTEMD_DIR}" ]; then
        SYSTEMD_DIR="${INSTALL_K3S_SYSTEMD_DIR}"
    else
        SYSTEMD_DIR=/etc/systemd/system
    fi

    # --- set related files from system name ---
    SERVICE_K3S=${SYSTEM_NAME}.service
    UNINSTALL_K3S_SH=${UNINSTALL_K3S_SH:-${BIN_DIR}/${SYSTEM_NAME}-uninstall.sh}
    KILLALL_K3S_SH=${KILLALL_K3S_SH:-${BIN_DIR}/k3s-killall.sh}

    # --- use service or environment location depending on systemd/openrc ---
    if [ "${HAS_SYSTEMD}" = true ]; then
        FILE_K3S_SERVICE=${SYSTEMD_DIR}/${SERVICE_K3S}
        FILE_K3S_ENV=${SYSTEMD_DIR}/${SERVICE_K3S}.env
    elif [ "${HAS_OPENRC}" = true ]; then
        $SUDO mkdir -p /etc/rancher/k3s
        FILE_K3S_SERVICE=/etc/init.d/${SYSTEM_NAME}
        FILE_K3S_ENV=/etc/rancher/k3s/${SYSTEM_NAME}.env
    fi

    # --- get hash of config & exec for currently installed k3s ---
    PRE_INSTALL_HASHES=$(get_installed_hashes)

    # --- if bin directory is read only skip download ---
    if [ "${INSTALL_K3S_BIN_DIR_READ_ONLY}" = true ]; then
        INSTALL_K3S_SKIP_DOWNLOAD=true
    fi

    # --- setup channel values
    INSTALL_K3S_CHANNEL_URL=${INSTALL_K3S_CHANNEL_URL:-'https://update.k3s.io/v1-release/channels'}
    INSTALL_K3S_CHANNEL=${INSTALL_K3S_CHANNEL:-'stable'}
}

# --- check if skip download environment variable set ---
can_skip_download() {
    if [ "${INSTALL_K3S_SKIP_DOWNLOAD}" != true ]; then
        return 1
    fi
}

# --- verify an executable k3s binary is installed ---
verify_k3s_is_executable() {
    if [ ! -x ${BIN_DIR}/k3s ]; then
        fatal "Executable k3s binary not found at ${BIN_DIR}/k3s"
    fi
}

# --- set arch and suffix, fatal if architecture not supported ---
setup_verify_arch() {
    if [ -z "$ARCH" ]; then
        ARCH=$(uname -m)
    fi
    case $ARCH in
    amd64)
        ARCH=amd64
        SUFFIX=
        ;;
    x86_64)
        ARCH=amd64
        SUFFIX=
        ;;
    arm64)
        ARCH=arm64
        SUFFIX=-${ARCH}
        ;;
    aarch64)
        ARCH=arm64
        SUFFIX=-${ARCH}
        ;;
    arm*)
        ARCH=arm
        SUFFIX=-${ARCH}hf
        ;;
    *)
        fatal "Unsupported architecture $ARCH"
        ;;
    esac
}

# --- verify existence of network downloader executable ---
verify_downloader() {
    # Return failure if it doesn't exist or is no executable
    [ -x "$(command -v $1)" ] || return 1

    # Set verified executable as our downloader program and return success
    DOWNLOADER=$1
    return 0
}

# --- create temporary directory and cleanup when done ---
setup_tmp() {
    TMP_DIR=$(mktemp -d -t k3s-install.XXXXXXXXXX)
    TMP_HASH=${TMP_DIR}/k3s.hash
    TMP_BIN=${TMP_DIR}/k3s.bin
    cleanup() {
        code=$?
        set +e
        trap - EXIT
        rm -rf ${TMP_DIR}
        exit $code
    }
    trap cleanup INT EXIT
}

# --- use desired k3s version if defined or find version from channel ---
get_release_version() {
    if [ -n "${INSTALL_K3S_COMMIT}" ]; then
        VERSION_K3S="commit ${INSTALL_K3S_COMMIT}"
    elif [ -n "${INSTALL_K3S_VERSION}" ]; then
        VERSION_K3S=${INSTALL_K3S_VERSION}
    else
        info "Finding release for channel ${INSTALL_K3S_CHANNEL}"
        version_url="${INSTALL_K3S_CHANNEL_URL}/${INSTALL_K3S_CHANNEL}"
        case $DOWNLOADER in
        curl)
            VERSION_K3S=$(curl -w '%{url_effective}' -L -s -S ${version_url} -o /dev/null | sed -e 's|.*/||')
            ;;
        wget)
            VERSION_K3S=$(wget -SqO /dev/null ${version_url} 2>&1 | grep -i Location | sed -e 's|.*/||')
            ;;
        *)
            fatal "Incorrect downloader executable '$DOWNLOADER'"
            ;;
        esac
    fi
    info "Using ${VERSION_K3S} as release"
}

# --- download from github url ---
download() {
    [ $# -eq 2 ] || fatal 'download needs exactly 2 arguments'

    case $DOWNLOADER in
    curl)
        curl -o $1 -sfL $2
        ;;
    wget)
        wget -qO $1 $2
        ;;
    *)
        fatal "Incorrect executable '$DOWNLOADER'"
        ;;
    esac

    # Abort if download command failed
    [ $? -eq 0 ] || fatal 'Download failed'
}

# --- download hash from github url ---
download_hash() {
    if [ -n "${INSTALL_K3S_COMMIT}" ]; then
        HASH_URL=${STORAGE_URL}/k3s${SUFFIX}-${INSTALL_K3S_COMMIT}.sha256sum
    else
        HASH_URL=${GITHUB_URL}/download/${VERSION_K3S}/sha256sum-${ARCH}.txt
    fi
    info "Downloading hash ${HASH_URL}"
    download ${TMP_HASH} ${HASH_URL}
    HASH_EXPECTED=$(grep " k3s${SUFFIX}$" ${TMP_HASH})
    HASH_EXPECTED=${HASH_EXPECTED%%[[:blank:]]*}
}

# --- check hash against installed version ---
installed_hash_matches() {
    if [ -x ${BIN_DIR}/k3s ]; then
        HASH_INSTALLED=$(sha256sum ${BIN_DIR}/k3s)
        HASH_INSTALLED=${HASH_INSTALLED%%[[:blank:]]*}
        if [ "${HASH_EXPECTED}" = "${HASH_INSTALLED}" ]; then
            return
        fi
    fi
    return 1
}

# --- download binary from github url ---
download_binary() {
    if [ -n "${INSTALL_K3S_COMMIT}" ]; then
        BIN_URL=${STORAGE_URL}/k3s${SUFFIX}-${INSTALL_K3S_COMMIT}
    else
        BIN_URL=${GITHUB_URL}/download/${VERSION_K3S}/k3s${SUFFIX}
    fi
    info "Downloading binary ${BIN_URL}"
    download ${TMP_BIN} ${BIN_URL}
}

# --- verify downloaded binary hash ---
verify_binary() {
    info "Verifying binary download"
    HASH_BIN=$(sha256sum ${TMP_BIN})
    HASH_BIN=${HASH_BIN%%[[:blank:]]*}
    if [ "${HASH_EXPECTED}" != "${HASH_BIN}" ]; then
        fatal "Download sha256 does not match ${HASH_EXPECTED}, got ${HASH_BIN}"
    fi
}

# --- setup permissions and move binary to system directory ---
setup_binary() {
    chmod 755 ${TMP_BIN}
    info "Installing k3s to ${BIN_DIR}/k3s"
    $SUDO chown root:root ${TMP_BIN}
    $SUDO mv -f ${TMP_BIN} ${BIN_DIR}/k3s
}

# --- setup selinux policy ---
setup_selinux() {
    case ${INSTALL_K3S_CHANNEL} in
    *testing)
        rpm_channel=testing
        ;;
    *latest)
        rpm_channel=latest
        ;;
    *)
        rpm_channel=stable
        ;;
    esac

    rpm_site="rpm.rancher.io"
    if [ "${rpm_channel}" = "testing" ]; then
        rpm_site="rpm-testing.rancher.io"
    fi

    [ -r /etc/os-release ] && . /etc/os-release
    if [ "${ID_LIKE%%[ ]*}" = "suse" ]; then
        rpm_target=sle
        rpm_site_infix=microos
        package_installer=zypper
    elif [ "${VERSION_ID%%.*}" = "7" ]; then
        rpm_target=el7
        rpm_site_infix=centos/7
        package_installer=yum
    else
        rpm_target=el8
        rpm_site_infix=centos/8
        package_installer=yum
    fi

    if [ "${package_installer}" = "yum" ] && [ -x /usr/bin/dnf ]; then
        package_installer=dnf
    fi

    policy_hint="please install:
    ${package_installer} install -y container-selinux
    ${package_installer} install -y https://${rpm_site}/k3s/${rpm_channel}/common/${rpm_site_infix}/noarch/k3s-selinux-0.4-1.${rpm_target}.noarch.rpm
"

    if [ "$INSTALL_K3S_SKIP_SELINUX_RPM" = true ] || can_skip_download || [ ! -d /usr/share/selinux ]; then
        info "Skipping installation of SELinux RPM"
    elif [ "${ID_LIKE:-}" != coreos ] && [ "${VARIANT_ID:-}" != coreos ]; then
        install_selinux_rpm ${rpm_site} ${rpm_channel} ${rpm_target} ${rpm_site_infix}
    fi

    policy_error=fatal
    if [ "$INSTALL_K3S_SELINUX_WARN" = true ] || [ "${ID_LIKE:-}" = coreos ] || [ "${VARIANT_ID:-}" = coreos ]; then
        policy_error=warn
    fi

    if ! $SUDO chcon -u system_u -r object_r -t container_runtime_exec_t ${BIN_DIR}/k3s >/dev/null 2>&1; then
        if $SUDO grep '^\s*SELINUX=enforcing' /etc/selinux/config >/dev/null 2>&1; then
            $policy_error "Failed to apply container_runtime_exec_t to ${BIN_DIR}/k3s, ${policy_hint}"
        fi
    elif [ ! -f /usr/share/selinux/packages/k3s.pp ]; then
        if [ -x /usr/sbin/transactional-update ]; then
            warn "Please reboot your machine to activate the changes and avoid data loss."
        else
            $policy_error "Failed to find the k3s-selinux policy, ${policy_hint}"
        fi
    fi
}

install_selinux_rpm() {
    if [ -r /etc/redhat-release ] || [ -r /etc/centos-release ] || [ -r /etc/oracle-release ] || [ "${ID_LIKE%%[ ]*}" = "suse" ]; then
        repodir=/etc/yum.repos.d
        if [ -d /etc/zypp/repos.d ]; then
            repodir=/etc/zypp/repos.d
        fi
        set +o noglob
        $SUDO rm -f ${repodir}/rancher-k3s-common*.repo
        set -o noglob
        if [ -r /etc/redhat-release ] && [ "${3}" = "el7" ]; then
            $SUDO yum install -y yum-utils
            $SUDO yum-config-manager --enable rhel-7-server-extras-rpms
        fi
        $SUDO tee ${repodir}/rancher-k3s-common.repo >/dev/null <<EOF
[rancher-k3s-common-${2}]
name=Rancher K3s Common (${2})
baseurl=https://${1}/k3s/${2}/common/${4}/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://${1}/public.key
EOF
        case ${3} in
        sle)
            rpm_installer="zypper --gpg-auto-import-keys"
            if [ "${TRANSACTIONAL_UPDATE=false}" != "true" ] && [ -x /usr/sbin/transactional-update ]; then
                rpm_installer="transactional-update --no-selfupdate -d run ${rpm_installer}"
                : "${INSTALL_K3S_SKIP_START:=true}"
            fi
            ;;
        *)
            rpm_installer="yum"
            ;;
        esac
        if [ "${rpm_installer}" = "yum" ] && [ -x /usr/bin/dnf ]; then
            rpm_installer=dnf
        fi
        # shellcheck disable=SC2086
        $SUDO ${rpm_installer} install -y "k3s-selinux"
    fi
    return
}

# --- download and verify k3s ---
download_and_verify() {
    if can_skip_download; then
        info 'Skipping k3s download and verify'
        verify_k3s_is_executable
        return
    fi

    setup_verify_arch
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    setup_tmp
    get_release_version
    download_hash

    if installed_hash_matches; then
        info 'Skipping binary downloaded, installed k3s matches hash'
        return
    fi

    download_binary
    verify_binary
    setup_binary
}

# --- add additional utility links ---
create_symlinks() {
    [ "${INSTALL_K3S_BIN_DIR_READ_ONLY}" = true ] && return
    [ "${INSTALL_K3S_SYMLINK}" = skip ] && return

    for cmd in kubectl crictl ctr; do
        if [ ! -e ${BIN_DIR}/${cmd} ] || [ "${INSTALL_K3S_SYMLINK}" = force ]; then
            which_cmd=$(command -v ${cmd} 2>/dev/null || true)
            if [ -z "${which_cmd}" ] || [ "${INSTALL_K3S_SYMLINK}" = force ]; then
                info "Creating ${BIN_DIR}/${cmd} symlink to k3s"
                $SUDO ln -sf k3s ${BIN_DIR}/${cmd}
            else
                info "Skipping ${BIN_DIR}/${cmd} symlink to k3s, command exists in PATH at ${which_cmd}"
            fi
        else
            info "Skipping ${BIN_DIR}/${cmd} symlink to k3s, already exists"
        fi
    done
}

# --- create killall script ---
create_killall() {
    [ "${INSTALL_K3S_BIN_DIR_READ_ONLY}" = true ] && return
    info "Creating killall script ${KILLALL_K3S_SH}"
    $SUDO tee ${KILLALL_K3S_SH} >/dev/null <<\EOF
#!/bin/sh
[ $(id -u) -eq 0 ] || exec sudo $0 $@
for bin in /var/lib/rancher/k3s/data/**/bin/; do
    [ -d $bin ] && export PATH=$PATH:$bin:$bin/aux
done
set -x
for service in /etc/systemd/system/k3s*.service; do
    [ -s $service ] && systemctl stop $(basename $service)
done
for service in /etc/init.d/k3s*; do
    [ -x $service ] && $service stop
done
pschildren() {
    ps -e -o ppid= -o pid= | \
    sed -e 's/^\s*//g; s/\s\s*/\t/g;' | \
    grep -w "^$1" | \
    cut -f2
}
pstree() {
    for pid in $@; do
        echo $pid
        for child in $(pschildren $pid); do
            pstree $child
        done
    done
}
killtree() {
    kill -9 $(
        { set +x; } 2>/dev/null;
        pstree $@;
        set -x;
    ) 2>/dev/null
}
getshims() {
    ps -e -o pid= -o args= | sed -e 's/^ *//; s/\s\s*/\t/;' | grep -w 'k3s/data/[^/]*/bin/containerd-shim' | cut -f1
}
killtree $({ set +x; } 2>/dev/null; getshims; set -x)
do_unmount_and_remove() {
    set +x
    while read -r _ path _; do
        case "$path" in $1*) echo "$path" ;; esac
    done < /proc/self/mounts | sort -r | xargs -r -t -n 1 sh -c 'umount "$0" && rm -rf "$0"'
    set -x
}
do_unmount_and_remove '/run/k3s'
do_unmount_and_remove '/var/lib/rancher/k3s'
do_unmount_and_remove '/var/lib/kubelet/pods'
do_unmount_and_remove '/var/lib/kubelet/plugins'
do_unmount_and_remove '/run/netns/cni-'
# Remove CNI namespaces
ip netns show 2>/dev/null | grep cni- | xargs -r -t -n 1 ip netns delete
# Delete network interface(s) that match 'master cni0'
ip link show 2>/dev/null | grep 'master cni0' | while read ignore iface ignore; do
    iface=${iface%%@*}
    [ -z "$iface" ] || ip link delete $iface
done
ip link delete cni0
ip link delete flannel.1
ip link delete flannel-v6.1
rm -rf /var/lib/cni/
iptables-save | grep -v KUBE- | grep -v CNI- | iptables-restore
EOF
    $SUDO chmod 755 ${KILLALL_K3S_SH}
    $SUDO chown root:root ${KILLALL_K3S_SH}
}

# --- create uninstall script ---
create_uninstall() {
    [ "${INSTALL_K3S_BIN_DIR_READ_ONLY}" = true ] && return
    info "Creating uninstall script ${UNINSTALL_K3S_SH}"
    $SUDO tee ${UNINSTALL_K3S_SH} >/dev/null <<EOF
#!/bin/sh
set -x
[ \$(id -u) -eq 0 ] || exec sudo \$0 \$@
${KILLALL_K3S_SH}
if command -v systemctl; then
    systemctl disable ${SYSTEM_NAME}
    systemctl reset-failed ${SYSTEM_NAME}
    systemctl daemon-reload
fi
if command -v rc-update; then
    rc-update delete ${SYSTEM_NAME} default
fi
rm -f ${FILE_K3S_SERVICE}
rm -f ${FILE_K3S_ENV}
remove_uninstall() {
    rm -f ${UNINSTALL_K3S_SH}
}
trap remove_uninstall EXIT
if (ls ${SYSTEMD_DIR}/k3s*.service || ls /etc/init.d/k3s*) >/dev/null 2>&1; then
    set +x; echo 'Additional k3s services installed, skipping uninstall of k3s'; set -x
    exit
fi
for cmd in kubectl crictl ctr; do
    if [ -L ${BIN_DIR}/\$cmd ]; then
        rm -f ${BIN_DIR}/\$cmd
    fi
done
rm -rf /etc/rancher/k3s
rm -rf /run/k3s
rm -rf /run/flannel
rm -rf /var/lib/rancher/k3s
rm -rf /var/lib/kubelet
rm -f ${BIN_DIR}/k3s
rm -f ${KILLALL_K3S_SH}
if type yum >/dev/null 2>&1; then
    yum remove -y k3s-selinux
    rm -f /etc/yum.repos.d/rancher-k3s-common*.repo
elif type zypper >/dev/null 2>&1; then
    uninstall_cmd="zypper remove -y k3s-selinux"
    if [ "\${TRANSACTIONAL_UPDATE=false}" != "true" ] && [ -x /usr/sbin/transactional-update ]; then
        uninstall_cmd="transactional-update --no-selfupdate -d run \$uninstall_cmd"
    fi
    \$uninstall_cmd
    rm -f /etc/zypp/repos.d/rancher-k3s-common*.repo
fi
EOF
    $SUDO chmod 755 ${UNINSTALL_K3S_SH}
    $SUDO chown root:root ${UNINSTALL_K3S_SH}
}

# --- disable current service if loaded --
systemd_disable() {
    $SUDO systemctl disable ${SYSTEM_NAME} >/dev/null 2>&1 || true
    $SUDO rm -f /etc/systemd/system/${SERVICE_K3S} || true
    $SUDO rm -f /etc/systemd/system/${SERVICE_K3S}.env || true
}

# --- capture current env and create file containing k3s_ variables ---
create_env_file() {
    info "env: Creating environment file ${FILE_K3S_ENV}"
    $SUDO touch ${FILE_K3S_ENV}
    $SUDO chmod 0600 ${FILE_K3S_ENV}
    sh -c export | while read x v; do echo $v; done | grep -E '^(K3S|CONTAINERD)_' | $SUDO tee ${FILE_K3S_ENV} >/dev/null
    sh -c export | while read x v; do echo $v; done | grep -Ei '^(NO|HTTP|HTTPS)_PROXY' | $SUDO tee -a ${FILE_K3S_ENV} >/dev/null
}

# --- write systemd service file ---
create_systemd_service_file() {
    info "systemd: Creating service file ${FILE_K3S_SERVICE}"
    $SUDO tee ${FILE_K3S_SERVICE} >/dev/null <<EOF
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target
[Install]
WantedBy=multi-user.target
[Service]
Type=${SYSTEMD_TYPE}
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
EnvironmentFile=-${FILE_K3S_ENV}
KillMode=process
Delegate=yes
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service'
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=${BIN_DIR}/k3s \\
    ${CMD_K3S_EXEC}

EOF
}

# --- write openrc service file ---
create_openrc_service_file() {
    LOG_FILE=/var/log/${SYSTEM_NAME}.log

    info "openrc: Creating service file ${FILE_K3S_SERVICE}"
    $SUDO tee ${FILE_K3S_SERVICE} >/dev/null <<EOF
#!/sbin/openrc-run
depend() {
    after network-online
    want cgroups
}
start_pre() {
    rm -f /tmp/k3s.*
}
supervisor=supervise-daemon
name=${SYSTEM_NAME}
command="${BIN_DIR}/k3s"
command_args="$(escape_dq "${CMD_K3S_EXEC}")
    >>${LOG_FILE} 2>&1"
output_log=${LOG_FILE}
error_log=${LOG_FILE}
pidfile="/var/run/${SYSTEM_NAME}.pid"
respawn_delay=5
respawn_max=0
set -o allexport
if [ -f /etc/environment ]; then source /etc/environment; fi
if [ -f ${FILE_K3S_ENV} ]; then source ${FILE_K3S_ENV}; fi
set +o allexport
EOF
    $SUDO chmod 0755 ${FILE_K3S_SERVICE}

    $SUDO tee /etc/logrotate.d/${SYSTEM_NAME} >/dev/null <<EOF
${LOG_FILE} {
	missingok
	notifempty
	copytruncate
}
EOF
}

# --- write systemd or openrc service file ---
create_service_file() {
    [ "${HAS_SYSTEMD}" = true ] && create_systemd_service_file
    [ "${HAS_OPENRC}" = true ] && create_openrc_service_file
    return 0
}

# --- get hashes of the current k3s bin and service files
get_installed_hashes() {
    $SUDO sha256sum ${BIN_DIR}/k3s ${FILE_K3S_SERVICE} ${FILE_K3S_ENV} 2>&1 || true
}

# --- enable and start systemd service ---
systemd_enable() {
    info "systemd: Enabling ${SYSTEM_NAME} unit"
    echo " " >>/etc/systemd/system/k3s.service
    $SUDO systemctl enable ${FILE_K3S_SERVICE} >/dev/null
    $SUDO systemctl daemon-reload >/dev/null
}

systemd_start() {
    info "systemd: Starting ${SYSTEM_NAME}"
    $SUDO systemctl restart ${SYSTEM_NAME}
}

# --- enable and start openrc service ---
openrc_enable() {
    info "openrc: Enabling ${SYSTEM_NAME} service for default runlevel"
    $SUDO rc-update add ${SYSTEM_NAME} default >/dev/null
}

openrc_start() {
    info "openrc: Starting ${SYSTEM_NAME}"
    $SUDO ${FILE_K3S_SERVICE} restart
}

#Nginx ingress install
Nginx_ingress() {

    if [ $INIT_MIDDLEWARE ]; then

        kubectl create ns ingress-nginx && kubectl -n ingress-nginx create secret docker-registry huawei-registry --docker-server=hub-dev.rockontrol.com --docker-username=pull-only --docker-password=h0nyhkLmNdZ9FWPc
        kubectl apply -f manifests/nginx-ingress.yaml -n ingress-nginx
        sleep 1
        kubectl rollout status daemonset -n ingress-nginx nginx-ingress-controller
        kubectl rollout status deployment -n ingress-nginx nginx-ingress-default-backend

    else
        info "Skiping install ingress..."
    fi

}

# --- startup systemd or openrc service ---
service_enable_and_start() {
    if [ -f "/proc/cgroups" ] && [ "$(grep memory /proc/cgroups | while read -r n n n enabled; do echo $enabled; done)" -eq 0 ]; then
        info 'Failed to find memory cgroup, you may need to add "cgroup_memory=1 cgroup_enable=memory" to your linux cmdline (/boot/cmdline.txt on a Raspberry Pi)'
    fi

    [ "${INSTALL_K3S_SKIP_ENABLE}" = true ] && return
    [ "${HAS_SYSTEMD}" = true ] && systemd_enable
    [ "${HAS_OPENRC}" = true ] && openrc_enable
    [ "${INSTALL_K3S_SKIP_START}" = true ] && return
    POST_INSTALL_HASHES=$(get_installed_hashes)
    if [ "${PRE_INSTALL_HASHES}" = "${POST_INSTALL_HASHES}" ] && [ "${INSTALL_K3S_FORCE_RESTART}" != true ]; then
        info 'No change detected so skipping service start'
        return
    fi
    [ "${HAS_SYSTEMD}" = true ] && systemd_start
    [ "${HAS_OPENRC}" = true ] && openrc_start
    return 0
}

print_info() {
    info "data path is /data..."
    info "enjoy!"
}

# --- re-evaluate args to include env command ---
eval set -- $(escape "${INSTALL_K3S_EXEC}") $(quote "$@")
# --- run the install process --
{
    check_env
    docker_check
    prepare_images
    verify_system
    setup_env "$@"
    download_and_verify
    Disable_SELinux
    setup_selinux
    create_symlinks
    create_killall
    create_uninstall
    systemd_disable
    create_env_file
    create_service_file
    service_enable_and_start
    Nginx_ingress
    print_info
}
