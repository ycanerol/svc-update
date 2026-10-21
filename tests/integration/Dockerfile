FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus python3 git ca-certificates \
      podman docker-compose uidmap fuse-overlayfs netavark aardvark-dns nftables iptables curl procps \
    && rm -rf /var/lib/apt/lists/*
RUN systemctl mask getty@tty1.service console-getty.service systemd-firstboot.service systemd-resolved.service 2>/dev/null; \
    printf '[storage]\ndriver = "vfs"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n' > /etc/containers/storage.conf; \
    printf '[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n' > /etc/containers/containers.conf; \
    printf 'unqualified-search-registries = ["docker.io"]\nshort-name-mode = "permissive"\n' > /etc/containers/registries.conf
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
