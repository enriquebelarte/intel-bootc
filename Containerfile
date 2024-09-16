ARG BASEIMAGE=registry.redhat.io/rhel9/rhel-bootc:9.4-1724170399
ARG DRIVER_TOOLKIT_IMAGE=registry.stage.redhat.io/rhelai1/driver-toolkit-rhel9:1.1-1724247729
ARG DRIVER_VERSION=1.17.1-40
ARG HABANA_REPO="https://vault.habana.ai/artifactory/rhel/9/9.4"

FROM ${DRIVER_TOOLKIT_IMAGE} as builder
ARG DRIVER_VERSION
ARG HABANA_REPO
# SHAs taken from original Makefile at HL packages
ARG DRIVER_GIT_SHA=78932ae
ARG NIC_GIT_SHA=31d590f

WORKDIR /home/builder

RUN . /etc/os-release \
    && export OS_VERSION_MAJOR=$(echo ${VERSION} | cut -d'.' -f 1) \
    && export KERNEL_VERSION=$(rpm -q --qf '%{VERSION}-%{RELEASE}' kernel-core) \
    && export TARGET_ARCH=$(rpm -q --qf '%{ARCH}' kernel-core) \
    && rpm2cpio ${HABANA_REPO}/habanalabs-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.noarch.rpm | cpio -idmv \
    && pushd usr/src/habanalabs-${DRIVER_VERSION} \
    && MAKE_IB=1 make -f Makefile.nic KVERSION=${KERNEL_VERSION}.${TARGET_ARCH} GIT_SHA=${DRIVER_GIT_SHA} NIC_KMD_GIT_SHA=${NIC_GIT_SHA} \
    && make -f Makefile KVERSION=${KERNEL_VERSION}.${TARGET_ARCH} \
    && pushd drivers/infiniband/hw/hbl \
    && make KVERSION=${KERNEL_VERSION}.${TARGET_ARCH}
####
FROM ${DRIVER_TOOLKIT_IMAGE} as libbuilder
ARG DRIVER_VERSION
ARG HABANA_REPO


USER root
COPY stage-rhelai1.2.repo /etc/yum.repos.d/stage-rhelai1.2.repo
COPY habana.repo /etc/yum.repos.d/habana.repo 
RUN update-crypto-policies --set DEFAULT:SHA1

RUN dnf install -y git make gcc-c++ unzip habanalabs-graph-${DRIVER_VERSION}.el9 libibverbs-devel
ENV LIBFABRIC_VERSION="1.20.0"
ENV LIBFABRIC_ROOT="/opt/habanalabs/libfabric-${LIBFABRIC_VERSION}"
ENV LD_LIBRARY_PATH=$LIBFABRIC_ROOT/lib:/usr/lib/habanalabs:$LD_LIBRARY_PATH
ENV PATH=${LIBFABRIC_ROOT}/bin:$PATH
ENV RDMAV_FORK_SAFE=1
ENV PIP_NO_CACHE_DIR=on
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV RDMA_CORE_ROOT=/opt/habanalabs/rdma-core/src
ENV RDMA_CORE_LIB=${RDMA_CORE_ROOT}/build/lib

RUN curl -L -o /tmp/libfabric-${LIBFABRIC_VERSION}.tar.bz2 https://github.com/ofiwg/libfabric/releases/download/v${LIBFABRIC_VERSION}/libfabric-${LIBFABRIC_VERSION}.tar.bz2 && \
    cd /tmp/ && tar xf /tmp/libfabric-${LIBFABRIC_VERSION}.tar.bz2 && \
    cd /tmp/libfabric-${LIBFABRIC_VERSION} && \
    ./configure --prefix=$LIBFABRIC_ROOT --enable-psm3-verbs --enable-verbs=yes --with-synapseai=/usr && \
    make && make install && cd / && rm -rf /tmp/libfabric-${LIBFABRIC_VERSION}.tar.bz2 /tmp/libfabric-${LIBFABRIC_VERSION}
#Hccl wrapper
RUN curl -L -o /tmp/main.zip https://github.com/HabanaAI/hccl_ofi_wrapper/archive/refs/heads/main.zip && \
    unzip /tmp/main.zip -d /tmp && \
    cd /tmp/hccl_ofi_wrapper-main && \
    make && cp -f libhccl_ofi_wrapper.so /usr/lib/habanalabs/libhccl_ofi_wrapper.so && \
    cd / && \
    rm -rf /tmp/main.zip /tmp/hccl_ofi_wrapper-main

FROM ${BASEIMAGE}
ARG DRIVER_VERSION="1.17.1-40"
ARG VENDOR=''
ARG IMAGE_VERSION_ID
LABEL vendor=${VENDOR}
LABEL org.opencontainers.image.vendor=${VENDOR}
USER root
COPY habana.repo /etc/yum.repos.d/habana.repo
COPY stage-rhelai1.2.repo /etc/yum.repos.d/stage-rhelai1.2.repo
COPY --from=builder /home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/accel/habanalabs/habanalabs.ko /tmp/extra/habanalabs.ko
COPY --from=builder /home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/infiniband/hw/hbl/habanalabs_ib.ko /tmp/extra/habanalabs_ib.ko
COPY --from=builder /home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/net/ethernet/intel/hbl_cn/habanalabs_cn.ko /tmp/extra/habanalabs_cn.ko
COPY --from=builder /home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/net/ethernet/intel/hbl_en/habanalabs_en.ko /tmp/extra/habanalabs_en.ko
COPY --from=builder /home/builder/etc/ /etc/
COPY --from=builder /home/builder/lib/firmware/habanalabs/gaudi/ /lib/firmware/habanalabs/gaudi/
COPY --from=builder /home/builder/usr/sbin /usr/sbin/
COPY --from=libbuilder /usr/lib/habanalabs/libhccl_ofi_wrapper.so /usr/lib/habanalabs/libhccl_ofi_wrapper.so
COPY --from=libbuilder /opt/habanalabs/libfabric-1.20.0 /opt/habanalabs/libfabric-1.20.0
RUN update-crypto-policies --set DEFAULT:SHA1
# Enable RHEL CRB (for libogg-devel )
RUN dnf config-manager -y --set-enabled codeready-builder-for-rhel-9-x86_64-rpms
#Install python3.11
RUN dnf install -y python3.11 python3.11-pip python3.11-devel
# Install build stuff
RUN dnf install -y git make gcc-c++ unzip
#Build ninja-build
RUN git clone https://github.com/ninja-build/ninja.git \
    && cd ninja \
    && ./configure.py --bootstrap
RUN . /etc/os-release \
    && export OS_VERSION_MAJOR=$(echo ${VERSION} | cut -d'.' -f 1) \
    && export KERNEL_VERSION=$(rpm -q --qf '%{VERSION}-%{RELEASE}' kernel-core) \
    && export TARGET_ARCH=$(rpm -q --qf '%{ARCH}' kernel-core) \
    && mv /etc/selinux /etc/selinux.tmp \
    && dnf -y update --exclude=kernel* \
    && dnf install -y libogg-devel libid3tag opusfile-devel sox-devel libnl3-devel \
    && dnf install -y habanalabs-rdma-core-${DRIVER_VERSION}.el9 \
    habanalabs-thunk-${DRIVER_VERSION}.el9 \
    habanalabs-firmware-${DRIVER_VERSION}.el9 \  
    habanalabs-firmware-tools-${DRIVER_VERSION}.el9 \
    habanalabs-graph-${DRIVER_VERSION}.el9 \
    habanalabs-qual-${DRIVER_VERSION}.el9 \
    habanalabs-firmware-odm-${DRIVER_VERSION}.el9 \
    && rm -f /etc/yum.repos.d/habanalabs.repo && rm -f /etc/yum.repos.d/habana.repo && \
    dnf clean all && rm -rf /var/cache/yum \
    && mv /etc/selinux.tmp /etc/selinux \
    && mv /tmp/extra /usr/lib/modules/${KERNEL_VERSION}.${TARGET_ARCH} \
    && echo "softdep habanalabs post: habanalabs_ib" > /etc/modprobe.d/habanalabs_ib_dep.conf \
    && depmod -a ${KERNEL_VERSION}.${TARGET_ARCH} \
    && rm -rf tmp/*

#
RUN python3.11 -m pip install pip==23.3.1 setuptools==67.3.3 wheel==0.38.4
RUN python3.11 -m pip install habana_media_loader=="1.17.1.40"
###############################
#RUN dnf install -y ${EXTRA_RPM_PACKAGES} \
#    cloud-init \
#    skopeo \
#    rsync \
#    && dnf clean all \
#    && ln -s ../cloud-init.target /usr/lib/systemd/system/default.target.wants
#
#ARG INSTRUCTLAB_IMAGE="quay.io/ai-lab/instructlab-intel:latest"
#
#ARG SSHPUBKEY

# The --build-arg "SSHPUBKEY=$(cat ~/.ssh/id_rsa.pub)" option inserts your
# public key into the image, allowing root access via ssh.
#RUN if [ -n "${SSHPUBKEY}" ]; then \
#    set -eu; mkdir -p /usr/ssh && \
#        echo 'AuthorizedKeysFile /usr/ssh/%u.keys .ssh/authorized_keys .ssh/authorized_keys2' >> /etc/ssh/sshd_config.d/30-auth-system.conf && \
#	    echo ${SSHPUBKEY} > /usr/ssh/root.keys && chmod 0600 /usr/ssh/root.keys; \
#fi

# Prepull the instructlab image
#RUN if [ -f "/run/.input/instructlab-intel/oci-layout" ]; then \
#         IID=$(podman --root /usr/lib/containers/storage pull oci:/run/.input/instructlab-intel) && \
#         podman --root /usr/lib/containers/storage image tag ${IID} ${INSTRUCTLAB_IMAGE}; \
#    else \
#         IID=$(sudo podman --root /usr/lib/containers/storage pull ${INSTRUCTLAB_IMAGE}); \
#    fi
#
