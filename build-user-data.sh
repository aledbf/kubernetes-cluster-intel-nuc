#!/bin/bash
set -e

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_VER=v1.1.3

# The CIDR network to use for pod IPs.
# Each pod launched in the cluster will be assigned an IP out of this range.
# Each node will be configured such that these IPs will be routable using the flannel overlay network.
export POD_NETWORK=10.2.0.0/16

# The CIDR network to use for service cluster IPs.
# Each service will be assigned a cluster IP out of this range.
# This must not overlap with any IP ranges assigned to the POD_NETWORK, or other existing network infrastructure.
# Routing to these IPs is handled by a proxy service local to each node, and are not required to be routable between nodes.
export SERVICE_IP_RANGE=10.3.0.0/22

# The IP address of the Kubernetes API Service
# If the SERVICE_IP_RANGE is changed above, this must be set to the first IP in that range.
export K8S_SERVICE_IP=10.3.0.1

# The Port of the Kubernetes API Service
export K8S_SERVICE_SSL_PORT=443

# The IP address of the cluster DNS service.
# This IP must be in the range of the SERVICE_IP_RANGE and cannot be the first IP in the range.
# This same IP must be configured on all worker nodes to enable DNS service discovery.
export DNS_SERVICE_IP=10.3.0.10

# Path to the public key to use to access the nodes using SSH
export PUBLIC_SSH_KEY=~/.ssh/id_rsa.pub

# Pattern of the names to create
export NODE_NAME_PATTERN=k8s

export NODE_GATEWAY=10.4.0.1

export NODE_START_IP=10.4.0.2

export NUMBER_NODES=4

export NET_IFACE=enp3s0

#-----------------------

function init_config {
  local REQUIRED=('NODE_START_IP' 'NUMBER_NODES' 'NODE_GATEWAY' 'NODE_NAME_PATTERN' 'SERVICE_IP_RANGE' 'PUBLIC_SSH_KEY' 'K8S_SERVICE_SSL_PORT' 'K8S_SERVICE_IP' 'DNS_SERVICE_IP' 'K8S_VER' 'POD_NETWORK')

  for REQ in "${REQUIRED[@]}"; do
    if [ -z "$(eval echo \$$REQ)" ]; then
      echo "Missing required config value: ${REQ}"
      exit 1
    fi
  done
}

function buildEtcdURL {
  # TODO: simplify
  url=""  
  IFS="." read -r a b c d <<< "$NODE_START_IP"
  count=1
  for ip in $(seq $(($d)) $(($NUMBER_NODES+$d-1)));do
    NODE_NAME=$NODE_NAME_PATTERN-$count
    url+="$NODE_NAME=http://$a.$b.$c.$ip:2380,"
    ((count++))
  done

  echo $url |sed 's/,$//'
}

function etcdURL {
  # TODO: simplify
  url=""  
  IFS="." read -r a b c d <<< "$NODE_START_IP"
  for ip in $(seq $(($d)) $(($NUMBER_NODES+$d-1)));do
    url+="http://$a.$b.$c.$ip:2379,"
  done

  echo $url |sed 's/,$//'
}

function buildSANIP {
  # TODO: simplify
  url=""  
  IFS="." read -r a b c d <<< "$NODE_START_IP"
  count=0
  for ip in $(seq $(($d)) $(($NUMBER_NODES+$d-1)));do
    url+="IP.$count=$a.$b.$c.$ip,"
    count+=1
  done

  echo $url |sed 's/,$//'
}

function createTemplates {
  IFS="." read -r a b c d <<< "$NODE_START_IP"
  count=1

  for ip in $(seq $(($d)) $(($NUMBER_NODES+$d-1)));do
    NODE_NAME=$NODE_NAME_PATTERN-$count
    NODE_IP=$a.$b.$c.$ip  
    TMPL=$(cat ./worker.template)

    if [ "$count" -eq "1" ]; then
      echo "adding master manifests..."
      TMPL=$(cat ./master.template)
    fi

    while IFS= read -r line ; do
      while [[ "$line" =~ (\$\{[a-zA-Z_][a-zA-Z_0-9]*\}) ]] ; do
      LHS=${BASH_REMATCH[1]}
      RHS="$(eval echo "\"$LHS\"")"
      line=${line//$LHS/$RHS}
      done
      echo -e "$line"
    done <<< "$TMPL" > user-data-$NODE_IP

    ((count++))
  done
}

function createManifests {
  FILES=./manifests-tmpl/*
  for templ in $FILES;do
    base=$(basename $templ)
    manifest="./manifests/$base"
    echo $manifest
    while IFS= read -r line ; do
      while [[ "$line" =~ (\$\{[a-zA-Z_][a-zA-Z_0-9]*\}) ]] ; do
      LHS=${BASH_REMATCH[1]}
      RHS="$(eval echo "\"$LHS\"")"
      line=${line//$LHS/$RHS}
      done
      echo -e "$line"
    done < $templ > $manifest
  done
}

echo "checking configuration..."
init_config

# List of etcd servers (http://ip:port), comma separated
ETCD_ENDPOINTS=$(buildEtcdURL)
ETCD_URL=$(etcdURL)

echo "creating SSL required certificates..."
mkdir -p ssl
./lib/init-ca.sh ./ssl
./lib/init-ssl.sh ./ssl apiserver kube-controller $(buildSANIP)
./lib/init-ssl.sh ./ssl worker kube-worker

echo "exporting cetificate to access apiserver from web browsers"
openssl pkcs12 -export -clcerts -inkey ./ssl/worker-key.pem -in ./ssl/worker.pem -out ./ssl/worker.p12 -name "worker"

CA_PEM=$(cat ./ssl/ca.pem | base64)
APISERVER_KEY_PEM=$(cat ./ssl/apiserver-key.pem | base64)
APISERVER_PEM=$(cat ./ssl/apiserver.pem | base64)

WORKER_KEY_PEM=$(cat ./ssl/worker-key.pem | base64)
WORKER_PEM=$(cat ./ssl/worker.pem | base64)

PUB_RSA=$(cat $PUBLIC_SSH_KEY)

MASTER_URL="https://$NODE_START_IP:$K8S_SERVICE_SSL_PORT"

mkdir -p manifests

createManifests

MANIFESTS=$(tar -cvzf - ./manifests | base64)

echo "creating initial user-data files..."

createTemplates

echo "done"
