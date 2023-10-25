#!/bin/sh
###
### my-script — does more thing well
###
### Usage:
###   my-script <arg1> <arg2>
###
### Options:
###   -           -
. ./docker-install.sh
###   docker      安装docker和docker-compose。


test() {
    echo "test"
}
###   ipip        更改脚本安装的k3s主节点ip。
ipip() {

    if cat /etc/hosts | grep 'k3s-custom-hub-dev' >/dev/null 2>&1; then
        echo "设置hosts.."

    else
        echo "124.70.75.116 hub-dev.rockontrol.com #by k3s-custom-hub-dev" >>/etc/hosts
    fi

    #获取ip并进行配置修改
    # private dns hosts for cluster
    if ifconfig | grep br0 >/dev/null; then
        ip=$(ip a | grep br0 | grep inet | awk -F ' ' '{print $2}' | cut -d "/" -f1)
    else
        ip=""
        read -p "未找到br0网卡,请直接输入本机ip:" ip
        info "设置本机IP为：$ip"
        check_ip $ip
    fi

    domain_custom="" && read -t 120 -ep "本地域名默认为[k3snode.local]，需自定义请直接输入:" domain_custom

    if [ ! $domain_custom ]; then
        domain_custom="k3snode.local"
    else
        sed -i "s/k3snode.local/$domain_custom/g" $(grep 'k3snode.local' -lr manifests)
    fi

    info "添加minio与api的dns配置!"
    dns_c="$ip minio.$domain_custom\n$ip api.$domain_custom\n" && kubectl patch cm coredns -n kube-system --type=json -p="[{\"op\":\"add\", \"path\":\"/data/NodeHosts\", \"value\":\"$dns_c\"}]"

}

###   hosts       添加hosts映射。
patchhosts() {
    sed -i '/k3s-custom-hub-dev/d' /etc/hosts
    echo "124.70.75.116 hub-dev.rockontrol.com #by k3s-custom-hub-dev" >>/etc/hosts
}

###   hub         docker-registry账户设置，参数为namespaces。
###                 eg:  hub middleware

hubsecret() {

    if [ $1 ]; then

        kubectl -n $1 create secret docker-registry huawei-registry \
            --docker-server=hub-dev.rockontrol.com \
            --docker-username=pull-only \
            --docker-password=h0nyhkLmNdZ9FWPc

    else
        echo "修改失败。"
        echo "需要指定namespaces。"
    fi

}

###   autocmd     k8s命令补全。
auto_command_k8s() {

    if [ -f /usr/share/bash-completion/bash_completion ]; then
        source /usr/share/bash-completion/bash_completion

        echo 'source <(kubectl completion bash)' >>~/.bashrc
        echo "配置完成，重启shell session或执行："
        echo "source <(kubectl completion bash)"
        echo "完成自动补全。"
    else
        echo "k8s自动补全命令依赖bash-completion！"
        if [ $(cat /etc/os-release | grep ubuntu | wc -l) != 0 ]; then
            apt install ./tools/bash-completion_1%3a2.10-1ubuntu1_all.deb
        elif [ $(cat /etc/os-release | grep centos | wc -l) != 0 ]; then
            yum install ./tools/bash-completion_1%3a2.10-1ubuntu1_all.deb
        else
            echo "需要手动安装以下依赖包："
            echo "tools/bash-completion_1%3a2.10-1ubuntu1_all.deb"
        fi

        echo 'source <(kubectl completion bash)' >>~/.bashrc
        echo "配置完成，重启shell session或执行："
        echo "source < (kubectl completion bash)"
        echo "完成自动补全。"

        #echo "可运行[type _init_completion]测试。"
    fi

}
###   middleware  安装pgsql/minio/redis中间件。
install_middleware() {

    echo "[INFO] prepare pgsql database data..."
    tar zxf tools/pgsql.tgz -C /
    echo "[INFO] prepare middleware images..."
    docker load -i images/middleware.tar
    echo "[INFO] deploy middleware pod..."

    kubectl create ns middleware && kubectl -n middleware create secret docker-registry huawei-registry --docker-server=hub-dev.rockontrol.com --docker-username=pull-only --docker-password=h0nyhkLmNdZ9FWPc
    kubectl apply -f manifests/middleware -n middleware

    kubectl rollout status deployment -n middleware pgsql
    kubectl rollout status deployment -n middleware minio
    kubectl rollout status deployment -n middleware redis

}

###   localpath   修改local-path默认存储路径
###                 eg:
###                    localpath /data/local-path
localpath() {
    if [ $1 ]; then
        kubectl get cm -n kube-system local-path-config -oyaml | sed "s#\"paths\":.*#\"paths\":[\"$s\"]#" | kubectl replace -f -

        echo "默认路径调整为：$1"
    else
        echo "修改失败。"
        echo "需要指定路径值。"
    fi

}

###   disupdate   禁止ubuntu18系统自动更新。
system_disable_update() {
    systemctl kill --kill-who=all apt-daily.service
    systemctl stop apt-daily.timer
    systemctl stop apt-daily-upgrade.timer
    systemctl stop apt-daily.service
    systemctl stop apt-daily-upgrade.service
    systemctl disable apt-daily.timer
    systemctl disable apt-daily-upgrade.timer
    systemctl disable apt-daily.service
    systemctl disable apt-daily-upgrade.service
    echo "已关闭系统自动更新！"
}

###   kuboard     安装kuboard。
kuboardins() {

    KUBOARD_BASE_DIR=/data/installtmp/kuboard/
    LOCAL_IP4=$(ip -o route get to 8.8.8.8 | sed -n 's/.*src \([0-9.]\+\).*/\1/p')
    #LOCAL_IP4=$(ifconfig  |sed -n '2p'|sed 's/Bcast.*$//'|sed 's@.*:@@'|awk '{print$2}')

    if [ -f $KUBOARD_BASE_DIR/start ]; then
        echo "文件已存在!"
    else
        mkdir -p $KUBOARD_BASE_DIR

        cat >$KUBOARD_BASE_DIR/start <<-EOF
#!/bin/bash
##--------------------------------------------

docker rm -f kuboard
kuboard_version="v3.5.0.3"
docker pull eipwork/kuboard:\$kuboard_version
docker run -d \\
  --restart=unless-stopped \\
  --name=kuboard \\
  -p 38080:80/tcp \\
  -p 10081:10081/tcp \\
  -p 10081:10081/udp \\
  -e KUBOARD_ENDPOINT="http://LOCAL_IP4:38080" \\
  -e KUBOARD_AGENT_SERVER_TCP_PORT="10081" \\
  -e KUBOARD_AGENT_SERVER_UDP_PORT="10081" \\
  -v KUBOARD_BASE_DIR/data:/data \\
  eipwork/kuboard:\$kuboard_version
  # 也可以使用镜像 swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v3 ，可以更快地完成镜像下载。
  # 请不要使用 127.0.0.1 或者 localhost 作为内网 IP 
  # Kuboard 不需要和 K8S 在同一个网段，Kuboard Agent 甚至可以通过代理访问 Kuboard Server 
  # 用户名： admin
  # 密 码： Kuboard123

echo "初次安装需要稍等1-3分钟即可登录。"
echo "初始信息："
echo "用户名： admin"
echo "密 码： Kuboard123"
echo "http://LOCAL_IP4:38080"
EOF

        sed -i "s#KUBOARD_BASE_DIR#$KUBOARD_BASE_DIR#g" $KUBOARD_BASE_DIR/start
        sed -i "s#LOCAL_IP4#$LOCAL_IP4#g" $KUBOARD_BASE_DIR/start

    fi
    echo "开始启动!"
    /bin/sh $KUBOARD_BASE_DIR/start

}

###   其他指令    输出该说明。
help() {
    sed -rn 's/^### ?//;T;p' "$0"
}

{

    case $1 in
    disupdate)
        echo '禁用系统更新：'
        system_disable_update
        ;;
    test)
        echo '这是一个测试：'
        test
        ;;
    kuboard)
        echo 'KUBOARD：'
        kuboardins
        ;;
    autocmd)
        echo 'k8s命令补全： '
        auto_command_k8s
        ;;
    middleware)
        echo '安装中间件： '
        install_middleware
        ;;
    localpath)
        echo '调整localhost默认数据路径： '
        localpath $2
        ;;
    hosts)
        echo '添加hosts映射： '
        patchhosts
        ;;
    hub)
        echo '添加仓库密钥： '
        hubsecret $2
        ;;
    docker_check)
        echo '安装docker和docker-compose：'
        $@
        ;;

    *)
        echo "ERROR 错误参数：$1"
        help
        exit 1
        ;;
    esac
}
