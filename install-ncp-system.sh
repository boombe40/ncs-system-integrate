#!/bin/bash

MYUSER=$(whoami)

echo '===== prepare virtualenv ====='
sudo apt update &>/dev/null
sudo apt install python3-venv python3-pip jq -y  &>/dev/null
ENVPATH=/opt/osenv

OS_PROJECTID=""
OS_USERNAME=""
OS_PASSWORD=""
OS_ACCESS_ID=""
OS_SECRET_KEY=""

if [ ! -f $ENVPATH ]; then
  python3 -m venv /opt/osenv
fi
source /opt/osenv/bin/activate  

if ! command -v openstack &> /dev/null
then
  pip install openstackclient  &>/dev/null
fi 

function check_environment {
  if ! command -v kubectl &> /dev/null
  then
      echo 'kubectl command not found, then starting install kubectl first.'
      curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
      chmod +x ./kubectl
      mv ./kubectl /usr/local/bin/kubectl
  fi

  if ! kubectl get node &> /dev/null; then
    echo 'Error! failed connect to kube-api'
    echo "Please create kubeconfig at /$MYUSER/.kube/config"
    exit 1;
  fi

  if ! command -v helm &> /dev/null
  then
      echo 'helm command not found, then starting install helm3 first.'
      curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

function get_authen_openstack {
  if [ -z "$OS_USERNAME" ] || [ -z "$OS_PASSWORD" ] || [ -z "$OS_PROJECTID" ]; then
    echo '===== Gethering information ====='
    echo -e 'login space.nipa.cloud'
    echo -n 'Username: '
    read OS_USERNAME
    echo -n 'Password: '
    read -s OS_PASSWORD

    echo -e 'ProjectID you install this cluster.'
    echo -e 'See your ProjectID from link: https://space.nipa.cloud/project'
    echo -n 'ProjectID: '
    read OS_PROJECTID
  fi
}

function login_openstack {

  cat > openrc.sh <<EOF
export OS_PROJECT_DOMAIN_NAME=nipacloud
export OS_USER_DOMAIN_NAME=nipacloud
export OS_PROJECT_ID=${OS_PROJECTID}
export OS_USERNAME=${OS_USERNAME}
export OS_PASSWORD=${OS_PASSWORD}
export OS_AUTH_URL=https://cloud-api.nipa.cloud:5000/v3
export OS_INTERFACE=public
export OS_ENDPOINT_TYPE=publicURL
export OS_IDENTITY_API_VERSION=3
export OS_REGION_NAME=NCP-TH
export OS_AUTH_PLUGIN=password
EOF

  source ./openrc.sh
  if ! openstack token issue &> /dev/null; then
    echo -e 'ERROR! please check your credential,incorrect Username Password'
    unset OS_USERNAME
    unset OS_PASSWORD
    unset OS_PROJECTID
    exit 1;
  fi
}
function create_application_credential {

  K8S_CLUSTERNAME=$(kubectl config current-context)
  application_credential_name="kubernetes-$OS_PROJECTID-$K8S_CLUSTERNAME-cluster"
  openstack application credential show $application_credential_name &> /dev/null
  RESULT=$?
  if [ $RESULT -eq 0 ]; then
    echo -e "Delete old application credential name: $application_credential_name"
    openstack application credential delete $application_credential_name
  fi
  echo -e "Create new application credential name: $application_credential_name"
  credential=$(openstack application credential create $application_credential_name -f json)
  OS_ACCESS_ID=$(echo $credential | jq -r '.id')
  OS_SECRET_KEY=$(echo $credential | jq -r '.secret')
}

function get_openstack_information {
  source openrc.sh
  instance_az=$(curl -s http://169.254.169.254/openstack/latest/meta_data.json | jq '.availability_zone' -r)
  network_id=$(curl -s http://169.254.169.254/openstack/latest/network_data.json | jq '.networks | .[] | .network_id ' -r)
  subnet_id=$(openstack subnet list --network $network_id -c ID -f value)

  echo -e '=== avialable Loadbalancer flavor ==='
  openstack loadbalancer flavor list --enable -c id -c name

  echo -e 'Select flavor you want to used.'
  echo -n 'loadbalancer id: '
  read OS_Loadbalancer_id
}

function install_csi {
  cat > CSI-value.yaml << EOF
storageClass:
  enabled: false
  delete:
    isDefault: true
    allowVolumeExpansion: true
  retain:
    isDefault: true
    allowVolumeExpansion: true
  custom: |-
    ---
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: standard-ssd
    provisioner: cinder.csi.openstack.org
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    parameters:
      type: Standard_SSD
    ---
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: premium-ssd
    provisioner: cinder.csi.openstack.org
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    parameters:
      type: Premium_SSD
    ---
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: standard-hdd
    provisioner: cinder.csi.openstack.org
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    parameters:
      type: Standard_HDD
secret:
  enabled: true
  create: true
  name: cinder-csi-cloud-config
  data:
    cloud.conf: |-
      [Global]
      auth-url=https://cloud-api.nipa.cloud:5000
      region=NCP-TH
      application-credential-id=$OS_ACCESS_ID
      application-credential-secret=$OS_SECRET_KEY

EOF
  helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
  helm repo update

  helm ls -n ncs-system | grep cinder-csi
  result=$?
  if [ $result -eq 0 ]; then  
    helm delete --namespace ncs-system cinder-csi 
  fi
  helm install cinder-csi cpo/openstack-cinder-csi -f ./CSI-value.yaml --namespace ncs-system --create-namespace
}
function install_ccm {
  cat > cloud.conf <<EOF
[Global]
auth-url=https://cloud-api.nipa.cloud:5000
region=NCP-TH
application-credential-id=$OS_ACCESS_ID
application-credential-secret=$OS_SECRET_KEY

[LoadBalancer]
use-octavia=true
subnet-id=$subnet_id
manage-security-groups=true
lb-provider=amphora
availability-zone=$instance_az
flavor-id=$OS_Loadbalancer_id
internal-lb=true
create-monitor=true
EOF
  kubectl get secret -n ncs-system cloud-config > /dev/null 2&>1
  RESULT=$?
  if [ $RESULT -eq 0 ]; then
    kubectl delete secret -n ncs-system cloud-config
  fi
  kubectl create secret -n ncs-system generic cloud-config --from-file=cloud.conf
  kubectl apply -f https://raw.githubusercontent.com/boombe40/ncs-system-integrate/main/src/controller-manager/cluster-role.yaml
  kubectl apply -f https://raw.githubusercontent.com/boombe40/ncs-system-integrate/main/src/controller-manager/cluster-role-binding.yaml
  kubectl apply -f https://raw.githubusercontent.com/boombe40/ncs-system-integrate/main/src/controller-manager/deamonset.yaml

}

check_environment
get_authen_openstack
login_openstack
create_application_credential
get_openstack_information
install_csi
install_ccm

