ARG DRIVER_TOOLKIT_IMAGE=quay.io/ebelarte/driver-toolkit:020924
ARG BASEIMAGE=quay.io/centos-bootc/centos-bootc:stream9

FROM ${DRIVER_TOOLKIT_IMAGE} as builder

# NOTE: The entire Gaudi stack from Kernel drivers to PyTorch and Instructlab
# must be updated in lockstep. Please coordinate updates with all
# stakeholders.
ARG DRIVER_VERSION=1.17.1-40
ARG HABANA_REPO="https://vault.habana.ai/artifactory/rhel/9/9.4"

WORKDIR /home/builder

RUN . /etc/os-release \
    && export OS_VERSION_MAJOR=$(echo ${VERSION} | cut -d'.' -f 1) \
    && export KERNEL_VERSION=$(rpm -q --qf '%{VERSION}-%{RELEASE}' kernel-core) \
    && export TARGET_ARCH=$(rpm -q --qf '%{ARCH}' kernel-core) \
    && rpm2cpio ${HABANA_REPO}/habanalabs-firmware-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.${TARGET_ARCH}.rpm | cpio -idmv \
    && rpm2cpio ${HABANA_REPO}/habanalabs-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.noarch.rpm | cpio -idmv \
    && rpm2cpio ${HABANA_REPO}/habanalabs-rdma-core-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.noarch.rpm | cpio -idmv \
    && rpm2cpio ${HABANA_REPO}/habanalabs-firmware-tools-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.${TARGET_ARCH}.rpm | cpio -idmv \
    && rpm2cpio ${HABANA_REPO}/habanalabs-thunk-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.${TARGET_ARCH}.rpm | cpio -idmv \ 
    && pushd usr/src/habanalabs-${DRIVER_VERSION} \
    && make -f Makefile.nic KVERSION=${KERNEL_VERSION}.${TARGET_ARCH} \
    && make -f Makefile KVERSION=${KERNEL_VERSION}.${TARGET_ARCH} \
    && pushd drivers/infiniband/hw/hbl \
    && make KVERSION=${KERNEL_VERSION}.${TARGET_ARCH}

FROM ${BASEIMAGE}

ARG DRIVER_VERSION=1.17.1-40
ARG EXTRA_RPM_PACKAGES=''

ARG VENDOR=''
LABEL vendor=${VENDOR}
LABEL org.opencontainers.image.vendor=${VENDOR}

COPY --from=builder /home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/accel/habanalabs/habanalabs.ko /tmp/extra/habanalabs.ko
COPY --from=builder /home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/infiniband/hw/hbl/habanalabs_ib.ko /tmp/extra/habanalabs_ib.ko
COPY --from=builder /home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/net/ethernet/intel/hbl_cn/habanalabs_cn.ko /tmp/extra/habanalabs_cn.ko
COPY --from=builder /home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/net/ethernet/intel/hbl_en/habanalabs_en.ko /tmp/extra/habanalabs_en.ko
COPY --from=builder /home/builder/lib/firmware/habanalabs /tmp/firmware/habanalabs

RUN . /etc/os-release \
    && export OS_VERSION_MAJOR=$(echo ${VERSION} | cut -d'.' -f 1) \
    && export KERNEL_VERSION=$(rpm -q --qf '%{VERSION}-%{RELEASE}' kernel-core) \
    && export TARGET_ARCH=$(rpm -q --qf '%{ARCH}' kernel-core) \
    && mv /tmp/extra /lib/modules/${KERNEL_VERSION}.${TARGET_ARCH} \
    && mv /tmp/firmware/habanalabs /lib/firmware \
    && depmod -a ${KERNEL_VERSION}.${TARGET_ARCH}

RUN dnf install -y ${EXTRA_RPM_PACKAGES} \
    cloud-init \
    skopeo \
    rsync \
    && dnf clean all \
    && ln -s ../cloud-init.target /usr/lib/systemd/system/default.target.wants

ARG INSTRUCTLAB_IMAGE="quay.io/ai-lab/instructlab-intel:latest"

ARG SSHPUBKEY

# The --build-arg "SSHPUBKEY=$(cat ~/.ssh/id_rsa.pub)" option inserts your
# public key into the image, allowing root access via ssh.
RUN if [ -n "${SSHPUBKEY}" ]; then \
    set -eu; mkdir -p /usr/ssh && \
        echo 'AuthorizedKeysFile /usr/ssh/%u.keys .ssh/authorized_keys .ssh/authorized_keys2' >> /etc/ssh/sshd_config.d/30-auth-system.conf && \
	    echo ${SSHPUBKEY} > /usr/ssh/root.keys && chmod 0600 /usr/ssh/root.keys; \
fi

# Prepull the instructlab image
#RUN if [ -f "/run/.input/instructlab-intel/oci-layout" ]; then \
#         IID=$(podman --root /usr/lib/containers/storage pull oci:/run/.input/instructlab-intel) && \
#         podman --root /usr/lib/containers/storage image tag ${IID} ${INSTRUCTLAB_IMAGE}; \
#    else \
#         IID=$(sudo podman --root /usr/lib/containers/storage pull ${INSTRUCTLAB_IMAGE}); \
#    fi
#
