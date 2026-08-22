FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG TARGETARCH=amd64
ARG KUBECTL_VERSION=v1.35.0
ARG KUBECTL_SHA256_AMD64=a2e984a18a0c063279d692533031c1eff93a262afcc0afdc517375432d060989
ARG KUBECTL_SHA256_ARM64=58f82f9fe796c375c5c4b8439850b0f3f4d401a52434052f2df46035a8789e25
ARG YQ_VERSION=v4.48.2
ARG YQ_SHA256_AMD64=0ffc35320180d4911bc3a772934da508715e08af444cb33d4d43660065e25bcc
ARG YQ_SHA256_ARM64=3c21630fda217239a5b7d718d08f08e02503098230b3abd49195d315a6dcfe45

LABEL org.opencontainers.image.title="cka-practice designated SSH target" \
      org.cka-practice.ssh-image-role="target" \
      org.cka-practice.base.release="ubuntu-24.04" \
      org.cka-practice.tool.kubectl="v1.35.0" \
      org.cka-practice.tool.yq="v4.48.2"

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash bash-completion ca-certificates curl iproute2 less man-db manpages \
       openssh-server procps sudo wget \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /bin/bash candidate \
    && passwd --delete candidate \
    && install -d -o candidate -g candidate -m 0700 /home/candidate/.ssh \
    && install -d -o candidate -g candidate -m 0700 /home/candidate/.kube \
    && install -d -o root -g root -m 0755 /etc/cka/kubeconfigs /run/sshd

RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) kubectl_sha="$KUBECTL_SHA256_AMD64"; yq_sha="$YQ_SHA256_AMD64" ;; \
      arm64) kubectl_sha="$KUBECTL_SHA256_ARM64"; yq_sha="$YQ_SHA256_ARM64" ;; \
      *) echo "unsupported target architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      --output /tmp/kubectl; \
    echo "${kubectl_sha}  /tmp/kubectl" | sha256sum --check --strict; \
    install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl; \
    ln -s kubectl /usr/local/bin/k; \
    curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
      --output /tmp/yq; \
    echo "${yq_sha}  /tmp/yq" | sha256sum --check --strict; \
    install -o root -g root -m 0755 /tmp/yq /usr/local/bin/yq; \
    rm -f /tmp/kubectl /tmp/yq

COPY files/sshd_config /etc/ssh/sshd_config
COPY files/cka-bashrc /etc/cka/bashrc
COPY files/cka-use-context /usr/local/bin/cka-use-context
COPY files/entrypoint.sh /usr/local/sbin/cka-target-entrypoint
COPY files/sudoers-cka /etc/sudoers.d/cka-candidate

RUN chmod 0644 /etc/ssh/sshd_config /etc/cka/bashrc \
    && chmod 0755 /usr/local/bin/cka-use-context /usr/local/sbin/cka-target-entrypoint \
    && chmod 0440 /etc/sudoers.d/cka-candidate \
    && printf '\n[ -r /etc/cka/bashrc ] && . /etc/cka/bashrc\n' >> /home/candidate/.bashrc \
    && printf '\n[ -r /etc/cka/bashrc ] && . /etc/cka/bashrc\n' >> /root/.bashrc \
    && chown candidate:candidate /home/candidate/.bashrc \
    && visudo --check \
    && /usr/sbin/sshd -t \
    && kubectl version --client \
    && yq --version \
    # The server remains, but the target deliberately has no outbound SSH client.
    && rm -f /usr/bin/ssh /usr/bin/slogin /usr/bin/scp /usr/bin/sftp \
    && ! command -v ssh >/dev/null 2>&1 \
    # Never bake reusable host identity into the image; entrypoint regenerates it.
    && rm -f /etc/ssh/ssh_host_*

EXPOSE 22

ENTRYPOINT ["/usr/local/sbin/cka-target-entrypoint"]
