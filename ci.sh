#!/bin/bash

# Check if the virtualization is supported on Linux
# verify the output is not empty
isVirtSupported=$(grep -E --color 'vmx|svm' /proc/cpuinfo)
if [ -z "$isVirtSupported" ]
then
    echo "Virtualization: FAIL"
    echo "$isVirtSupported" > log
    exit 1
else
    echo "Virtualization: OK"
fi

function downloadKubectl() {
    echo "Trying to fix it ..."
    curl -LO https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl
    chmod +x ./kubectl
    # This required passwordless sudo if you want to make it automated
    sudo mv ./kubectl /usr/local/bin/kubectl
    return 0
}

# You need to have kubectl installed
if ! which kubectl &> /dev/null
then
    echo "kubectl: FAIL"
    if ! downloadKubectl; then
        exit 1
    fi
    echo "kubectl: OK"
else
    echo "kubectl: OK"
fi

# Check the version that is installed
# It must be the same with the upstream
kubectlUpstreamVersion=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
kubectlLocalVersion=$(kubectl version --client=true --short=true | cut -f2 -d ':' | sed -e 's/^[[:space:]]*//')
if [ "$kubectlUpstreamVersion" == "$kubectlLocalVersion" ]; then
    echo "kubectl version: OK (Upstream $kubectlUpstreamVersion matches with the local $kubectlLocalVersion)"
else
    echo "kubectl version: FAIL (Upstream $kubectlUpstreamVersion does not match with the local $kubectlLocalVersion)"
    if ! downloadKubectl; then
        exit 1
    fi
    echo "kubectl version: OK"
fi

function enableNestedVirtualization() {
    # Read: https://docs.fedoraproject.org/en-US/quick-docs/using-nested-virtualization-in-kvm/index.html
    # For Intel processors
    sudo modprobe -r kvm_intel # Unload the kvm_probe module
    sudo modprobe kvm_intel nested=1 # Activate the nested feature
    return 0
}

# Check for nested virtualization on the host
# where Minikube is installed on
isNestedVirtualization=$(cat /sys/module/kvm_intel/parameters/nested)
if [ "$isNestedVirtualization" == "N" ]; then
    echo "Nested Virtualization: FAIL"
    if ! enableNestedVirtualization; then
        exit 1
    fi
    echo "Nested Virtualization: OK"
else
    echo "Nested Virtualization: OK"
fi

# Check for KVM2 driver so Minikube can work
# using the libvirt virtualization API
# For Debian
if grep Debian /etc/os-release &> /dev/null
then
    # Installation
    if sudo apt-get -y --allow-unauthenticated --allow-downgrades --allow-downgrades --allow-change-held-packages install --no-install-recommends qemu-kvm libvirt-clients libvirt-daemon-system virtinst &> /dev/null
    then
        echo "KVM Packages: OK"
    else
        echo "KVM Packages: FAIL"
        exit 1
    fi
    # Connecting to local libvirt as regular user
    myUser=$(whoami)
    if awk '/drpaneas/ && /libvirt/' /etc/group  &> /dev/null; then
        echo "libvirt regular user: OK"
    else
        echo "libvirt regular user: FAIL"
        sudo adduser $myUser libvirt
        if ! awk '/drpaneas/ && /libvirt/' /etc/group  &> /dev/null; then
            echo "Tryin to fix it ..."
            echo "libvirt regular user: FAIL"
            exit 1
        fi
        echo "libvirt regular user: OK"
    fi
    if virsh list --all  &> /dev/null
    then
        echo "virsh list: OK"
    else
        echo "virsh list: FAIL"
    fi
    # Connecting to remote libvirt
    export LIBVIRT_DEFAULT_URI='qemu:///system'
    virsh list --all  &> /dev/null
    # Start default netork
    virsh --connect=qemu:///system net-start default
    # Make the default network start automatically
    virsh --connect=qemu:///system net-autostart default
fi

# Check for libvirt validation report
if virt-host-validate  &> /dev/null; then
    echo "libvirt report: OK"
else
    echo "libvirt report: FAIL"
    exit 1
fi

function downloadMinikube() {
    curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 &> /dev/null
    chmod +x minikube &> /dev/null
    sudo mkdir -p /usr/local/bin/ &> /dev/null
    sudo install minikube /usr/local/bin/ &> /dev/null
    return 0
}

# You need to have minikube installed
if which minikube &> /dev/null; then
    echo "minikube: OK"
else
    echo "minikue: FAIL"
    if ! downloadMinikube; then
        exit 1
    fi
    echo "minikube: OK"
fi

# Check the minikube version
minikubeUpstream=$(curl --silent https://github.com/kubernetes/minikube/releases/latest | awk -F "tag/" '{print $2}' | awk -F '"' '{ print $1 }')
minikubeLocal=$(minikube version | cut -f2 -d ':' | sed -e 's/^[[:space:]]*//' | head -n 1)
if [ "$minikubeUpstream" == "$minikubeLocal" ]; then
    echo "Minikube version: OK (Upstream $minikubeUpstream matches the local $minikubeLocal"
else
    echo "Minikube version: OK (Upstream $minikubeUpstream does not match the local $minikubeLocal"
    if ! downloadMinikube; then
        exit 1
    fi
    echo "minikube: OK"
fi

# Create a profile for KubeVirt so it gets its own settings without interfering with
# any configuration you might already have
minikube config -p kubevirt set memory 4096     # 4GB RAM
minikube config -p kubevirt set vm-driver kvm2  # set the VM driver to KVM2

# Start MinikubeVM
minikube start -p kubevirt

# Deploy KubeVirt operator
# On Linux you can obtain it using 'curl' via:
export KUBEVIRT_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases|grep tag_name|sort -V | tail -1 | awk -F':' '{print $2}' | sed 's/,//' | xargs | cut -d'-' -f1)
echo $KUBEVIRT_VERSION

# Deploy KubeVirt operator
kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml
kubectl wait --timeout=5m --for=condition=Ready pods --all --namespace=kubevirt --field-selector=status.phase!=Succeeded

# Check if the VM's CPU supports virtualization extensions
if minikube ssh -p kubevirt "egrep 'svm|vmx' /proc/cpuinfo"  &> /dev/null; then
    echo "VM virtualization: OK"
else
    echo "VM virtualization: FAIL"
fi

# Deploy KubeVirt by creating a dedicated custom resource
kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml
kubectl wait --timeout=10m --for=condition=Ready pods --all --namespace=kubevirt --field-selector=status.phase!=Succeeded


# Install virtctl
# To get quick access to the serial and graphical ports of a VM and handle start/stop operations
curl -L -o virtctl \
https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
chmod +x virtctl

# Delete it
minikube delete -p kubevirt