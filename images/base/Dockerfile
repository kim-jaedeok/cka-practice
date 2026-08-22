FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

LABEL org.opencontainers.image.title="cka-practice SSH base host" \
      org.cka-practice.ssh-image-role="base" \
      org.cka-practice.base.release="ubuntu-24.04"

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/candidate

# The base host intentionally contains only the client needed to enter the
# designated host.  It has no sudo and no CKA work tools.
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /bin/bash candidate \
    && rm -f /usr/bin/man \
    && for tool in kubectl k yq curl wget man sudo; do \
         if command -v "$tool" >/dev/null 2>&1; then \
           echo "unexpected base-host tool: $tool" >&2; exit 1; \
         fi; \
       done

COPY files/cka-ssh.conf /etc/ssh/ssh_config.d/cka-ssh.conf
COPY --chown=10001:10001 files/bashrc /home/candidate/.bashrc

RUN chmod 0644 /etc/ssh/ssh_config.d/cka-ssh.conf /home/candidate/.bashrc

USER 10001:10001
WORKDIR /home/candidate

CMD ["bash"]
