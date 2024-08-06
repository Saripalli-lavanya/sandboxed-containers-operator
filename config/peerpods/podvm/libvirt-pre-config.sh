#!/bin/bash

ACTION=$1
SSH_KEY_PASSPHRASE=$2
NAMESPACE="openshift-sandboxed-containers-operator"
SECRET_NAME="peer-pods-secret"

if [ -z "$KVM_HOST_ADDRESS" ]; then
    KVM_HOST_ADDRESS=$(oc get secret ocp-libvirt-secret -n "$NAMESPACE" -o jsonpath="{.data.LPAR_IP}" | base64 --decode)
fi

if [ -z "$KVM_HOST_USERNAME" ]; then
    KVM_HOST_USERNAME=$(oc get secret ocp-libvirt-secret -n "$NAMESPACE" -o jsonpath="{.data.LPAR_USER}" | base64 --decode)
fi

if [ -z "$KVM_HOST_PASSWORD" ]; then
    KVM_HOST_PASSWORD=$(oc get secret ocp-libvirt-secret -n "$NAMESPACE" -o jsonpath="{.data.LPAR_PSWD}" | base64 --decode)
fi

if [ -z "$HOST_KEY_CERTS" ]; then
    HOST_KEY_CERTS=$(oc get secret ocp-libvirt-secret -n "$NAMESPACE" -o jsonpath="{.data.HOST_KEY_CERTS}" | base64 --decode)
fi

if [ -z "$REDHAT_OFFLINE_TOKEN" ]; then
    REDHAT_OFFLINE_TOKEN=$(oc get secret ocp-libvirt-secret -n "$NAMESPACE" -o jsonpath="{.data.REDHAT_OFFLINE_TOKEN}" | base64 --decode)
fi

if [ -z "$KVM_HOST_ADDRESS" ] || [ -z "$KVM_HOST_USERNAME" ] || [ -z "$KVM_HOST_PASSWORD" ]; then
    echo "Error: KVM host IP or credentials are missing."
    exit 1
fi

if [ -z "$USER_LIBVIRT_POOL" ]; then
    USER_LIBVIRT_POOL=$(oc get secret ocp-libvirt-secret -n "$NAMESPACE" -o jsonpath="{.data.LIBVIRT_POOL}" | base64 --decode)
    if [ -z "$USER_LIBVIRT_POOL" ]; then
        USER_LIBVIRT_POOL="pool-auto-$(date +"%Y%m%d%H%M%S")"
    fi
fi

if [ -z "$USER_LIBVIRT_VOL_NAME" ]; then
    USER_LIBVIRT_VOL_NAME=$(oc get secret ocp-libvirt-secret -n "$NAMESPACE" -o jsonpath="{.data.LIBVIRT_VOLUME}" | base64 --decode)
    if [ -z "$USER_LIBVIRT_VOL_NAME" ]; then
        USER_LIBVIRT_VOL_NAME="vol-auto-$(date +"%Y%m%d%H%M%S")"
    fi
fi

if [ -z "$USER_LIBVIRT_POOL_FOLDER" ]; then
    USER_LIBVIRT_POOL_FOLDER=$(oc get secret ocp-libvirt-secret -n "$NAMESPACE" -o jsonpath="{.data.LIBVIRT_VOL_DIRECTORY}" | base64 --decode)
    USER_LIBVIRT_POOL_DIRECTORY="/var/lib/libvirt/images/$USER_LIBVIRT_POOL_FOLDER"
    if [ -z "$USER_LIBVIRT_POOL_FOLDER" ]; then
        USER_LIBVIRT_POOL_DIRECTORY="/var/lib/libvirt/images/dir-auto-$(date +"%Y%m%d%H%M%S")"
    fi
fi


SECRET_YAML=$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: "$SECRET_NAME"
  namespace: "$NAMESPACE"
type: Opaque
stringData:
  CLOUD_PROVIDER: "libvirt"
  LIBVIRT_URI: "qemu+ssh://root@192.168.122.1/system?no_verify=1"
  LIBVIRT_POOL: "$USER_LIBVIRT_POOL"
  LIBVIRT_VOL_NAME: "$USER_LIBVIRT_VOL_NAME"
  REDHAT_OFFLINE_TOKEN: "$REDHAT_OFFLINE_TOKEN"
  HOST_KEY_CERTS: |
    $HOST_KEY_CERTS
EOF
)

CONFIGMAP_YAML=$(cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: peer-pods-cm
  namespace: openshift-sandboxed-containers-operator
data:
  CLOUD_PROVIDER: "libvirt"
  PROXY_TIMEOUT: "15m"
EOF
)

install_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        echo "Installing sshpass..."
        yum install -y sshpass
    fi
}

generate_ssh_keys() {
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "${SSH_KEY_PASSPHRASE}" >/dev/null 2>&1
    sshpass -p "${KVM_HOST_PASSWORD}" ssh-copy-id -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${KVM_HOST_ADDRESS}" >/dev/null 2>&1

    oc create secret generic ssh-key-secret \
        -n openshift-sandboxed-containers-operator \
        --from-file=id_rsa.pub=/root/.ssh/id_rsa.pub \
        --from-file=id_rsa=/root/.ssh/id_rsa

    echo "SSH keypair generated and copied to ${KVM_HOST_ADDRESS}, Kubernetes secret created."
}

create_pool_volume_on_kvm_and_sync_sshid() {
    local kvm_host_user="$1"
    local kvm_host_address="$2"
    local libvirt_pool="$3"
    local libvirt_vol_name="$4"
    local libvirt_pool_directory="$5"

    echo "Creating pool and volume on KVM host '${kvm_host_address}'..."
    ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${kvm_host_address}" << EOF
        sudo mkdir "$libvirt_pool_directory"
        echo "Created directory: $libvirt_pool_directory"
        sudo virsh pool-define-as "${libvirt_pool}" --type dir --target "$libvirt_pool_directory"
        sudo virsh pool-start "${libvirt_pool}"
        sudo virsh -c qemu:///system vol-create-as --pool "${libvirt_pool}" \
            --name "${libvirt_vol_name}" \
            --capacity 20G \
            --allocation 2G \
            --prealloc-metadata \
            --format qcow2
        sudo cat /home/$kvm_host_user/.ssh/authorized_keys | sudo tee -a /root/.ssh/authorized_keys > /dev/null 2>&1
EOF
}

check_pool_and_volume_existence() {
    local kvm_host_address="$1"
    local libvirt_pool="$2"
    local libvirt_vol_name="$3"

    echo "Checking existence of libvirt pool '${libvirt_pool}' and volume '${libvirt_vol_name}' on KVM host '${kvm_host_address}'..."
    ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${kvm_host_address}" << EOF
        sudo virsh pool-info "${libvirt_pool}" >/dev/null 2>&1
        POOL_EXISTS=\$?
        sudo virsh vol-info --pool "${libvirt_pool}" "${libvirt_vol_name}" >/dev/null 2>&1
        VOL_EXISTS=\$?

        if [ "\$POOL_EXISTS" -eq 0 ] && [ "\$VOL_EXISTS" -eq 0 ]; then
            echo "A Libvirt pool named '${libvirt_pool}' with volume '${libvirt_vol_name}' already exists on the KVM host. Please choose a different name."
            exit 0
        else
            echo "Libvirt pool '${libvirt_pool}' or volume '${libvirt_vol_name}' does not exist. Proceeding to create..."
        fi
EOF
}

create_configMap_and_secret() {
    echo "$SECRET_YAML" | oc apply -f -
    echo "$CONFIGMAP_YAML" | oc apply -f -
}

cleanup() {
    echo "Cleaning up..."

    # Extract current values from the secret
    USER_LIBVIRT_POOL=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.LIBVIRT_POOL}" | base64 --decode)
    USER_LIBVIRT_VOL_NAME=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.LIBVIRT_VOL_NAME}" | base64 --decode)
    
    if [ -z "$USER_LIBVIRT_POOL" ] || [ -z "$USER_LIBVIRT_VOL_NAME" ]; then
        echo "Error: Missing pool or volume name in the secret."
        exit 1
    fi

    # Check if the pool exists
    if ! ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${KVM_HOST_ADDRESS}" sudo virsh pool-info "$USER_LIBVIRT_POOL" >/dev/null 2>&1; then
        echo "Pool '$USER_LIBVIRT_POOL' does not exist on KVM host."
        exit 1
    fi

    # List volumes in the pool
    VOLUMES=$(ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${KVM_HOST_ADDRESS}" sudo virsh vol-list "$USER_LIBVIRT_POOL" | awk 'NR>2 {print $1}')
    if [ "$VOLUMES" == "$USER_LIBVIRT_VOL_NAME" ]; then
        echo "Volume '$USER_LIBVIRT_VOL_NAME' is the only volume in the pool. Deleting the volume."

        if ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${KVM_HOST_ADDRESS}" sudo virsh vol-delete "$USER_LIBVIRT_VOL_NAME" --pool "$USER_LIBVIRT_POOL"; then
            echo "Volume '$USER_LIBVIRT_VOL_NAME' deleted successfully."

            # Check if the pool is now empty
            VOLUMES=$(ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${KVM_HOST_ADDRESS}" sudo virsh vol-list "$USER_LIBVIRT_POOL" | awk 'NR>2 {print $1}')
            if [ -z "$VOLUMES" ]; then
                echo "No volumes found in the pool. Proceeding to delete the pool & libvirt directory"
                if ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${KVM_HOST_ADDRESS}" sudo virsh pool-destroy "$USER_LIBVIRT_POOL"; then
                    echo "Pool '$USER_LIBVIRT_POOL' destroyed successfully."
                    if ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no "${KVM_HOST_USERNAME}@${KVM_HOST_ADDRESS}" sudo virsh pool-undefine "$USER_LIBVIRT_POOL"; then
                        echo "Pool '$USER_LIBVIRT_POOL' undefined successfully."
                    else
                        echo "Failed to undefine the pool '$USER_LIBVIRT_POOL'."
                        exit 1
                    fi
                else
                    echo "Failed to destroy the pool '$USER_LIBVIRT_POOL'."
                    exit 1
                fi
                sudo rm -rf "$USER_LIBVIRT_POOL_DIRECTORY" 2>/dev/null || echo "Directory '${USER_LIBVIRT_POOL_DIRECTORY}' could not be removed."

            else
                echo "Error: Volume '$USER_LIBVIRT_VOL_NAME' was deleted, but other volumes remain in the pool."
            fi
        else
            echo "Failed to delete the volume '$USER_LIBVIRT_VOL_NAME'."
            exit 1
        fi
    else
        echo "Volume '$USER_LIBVIRT_VOL_NAME' is not the only volume in the pool. Not deleting the volume or pool."
        echo "Volumes in the pool:"
        echo "$VOLUMES"
    fi

    # Delete Kubernetes secrets and configmaps
    oc delete secret ssh-key-secret -n openshift-sandboxed-containers-operator
    oc delete configmap peer-pods-cm -n openshift-sandboxed-containers-operator
    oc delete secret "$SECRET_NAME" -n "$NAMESPACE"
    echo "Cleanup completed."
}

if [ "$ACTION" == "create" ]; then
    install_sshpass
    generate_ssh_keys
    check_pool_and_volume_existence "${KVM_HOST_ADDRESS}" "${USER_LIBVIRT_POOL}" "${USER_LIBVIRT_VOL_NAME}"
    create_pool_volume_on_kvm_and_sync_sshid "${KVM_HOST_USERNAME}" "${KVM_HOST_ADDRESS}" "${USER_LIBVIRT_POOL}" "${USER_LIBVIRT_VOL_NAME}" "${USER_LIBVIRT_POOL_DIRECTORY}"
    create_configMap_and_secret
elif [ "$ACTION" == "clean" ]; then
    install_sshpass
    generate_ssh_keys
    cleanup
else
    echo "Invalid action. Please use 'create' or 'clean'."
    exit 1
fi
