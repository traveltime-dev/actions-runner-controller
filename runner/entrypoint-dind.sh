#!/bin/bash
source logger.sh
source graceful-stop.sh
trap graceful_stop TERM

sudo /bin/bash <<SCRIPT
mkdir -p /etc/docker

if [ ! -f /etc/docker/daemon.json ]; then
  echo "{}" > /etc/docker/daemon.json
fi

if [ -n "${MTU}" ]; then
jq ".\"mtu\" = ${MTU}" /etc/docker/daemon.json > /tmp/.daemon.json && mv /tmp/.daemon.json /etc/docker/daemon.json
# See https://docs.docker.com/engine/security/rootless/
export DOCKERD_ROOTLESS_ROOTLESSKIT_MTU=${MTU}
fi

if [ -n "${DOCKER_DEFAULT_ADDRESS_POOL_BASE}" ] && [ -n "${DOCKER_DEFAULT_ADDRESS_POOL_SIZE}" ]; then
  jq ".\"default-address-pools\" = [{\"base\": \"${DOCKER_DEFAULT_ADDRESS_POOL_BASE}\", \"size\": ${DOCKER_DEFAULT_ADDRESS_POOL_SIZE}}]" /etc/docker/daemon.json > /tmp/.daemon.json && mv /tmp/.daemon.json /etc/docker/daemon.json
fi

if [ -n "${DOCKER_REGISTRY_MIRROR}" ]; then
jq ".\"registry-mirrors\"[0] = \"${DOCKER_REGISTRY_MIRROR}\"" /etc/docker/daemon.json > /tmp/.daemon.json && mv /tmp/.daemon.json /etc/docker/daemon.json
fi

if [ -n "${DOCKER_INSECURE_REGISTRY}" ]; then
jq ".\"insecure-registries\"[0] = \"${DOCKER_INSECURE_REGISTRY}\"" /etc/docker/daemon.json > /tmp/.daemon.json && mv /tmp/.daemon.json /etc/docker/daemon.json
fi
SCRIPT

dumb-init bash <<'SCRIPT' &
source logger.sh
source wait.sh

dump() {
  local path=${1:?missing required <path> argument}
  shift
  printf -- "%s\n---\n" "${*//\{path\}/"$path"}" 1>&2
  cat "$path" 1>&2
  printf -- '---\n' 1>&2
}

for config in /etc/docker/daemon.json; do
  dump "$config" 'Using {path} with the following content:'
done

log.debug 'Starting Docker daemon'
sudo /usr/bin/dockerd &

log.debug 'Waiting for processes to be running...'
processes=(dockerd)

for process in "${processes[@]}"; do
    if ! wait_for_process "$process"; then
        log.error "$process is not running after max time"
        exit 1
    else
        log.debug "$process is running"
    fi
done

# Grant the docker group access to dockerd's embedded containerd socket so
# rules_img's image_load takes the containerd-direct path (incremental layer
# pulls, content-store dedup of concurrent fetches, no fragile HTTP/2-stream-
# into-`docker load`-stdin pipe). Docker 29+ defaults the image store to
# containerd-snapshotter on a fresh dockerd.
#
# Detection runs under sudo: /run/docker/ is mode 0700 root:root, so the
# unprivileged runner user can't traverse it to stat the socket without
# elevation. After detection both parent dirs also need g+rx so the docker
# group can reach the socket; chgrp alone isn't enough.
#
# No new privilege surface: the docker group is already root-equivalent
# via /var/run/docker.sock.
CONTAINERD_SOCK=/run/docker/containerd/containerd.sock
CONTAINERD_SOCK_WAIT_S=30
log.notice "waiting up to ${CONTAINERD_SOCK_WAIT_S}s for embedded containerd socket at $CONTAINERD_SOCK..."
sock_found_iter=0
for i in $(seq 1 $((CONTAINERD_SOCK_WAIT_S * 10))); do
  if sudo test -S "$CONTAINERD_SOCK"; then
    sock_found_iter=$i
    break
  fi
  sleep 0.1
done
if [ "$sock_found_iter" -gt 0 ]; then
  log.notice "containerd socket appeared after $(printf '%d.%01d' $((sock_found_iter / 10)) $((sock_found_iter % 10)))s; granting docker-group access"
  sudo chgrp docker /run/docker /run/docker/containerd "$CONTAINERD_SOCK"
  sudo chmod g+rx /run/docker /run/docker/containerd
  sudo chmod 660 "$CONTAINERD_SOCK"
  log.notice "post-chmod perms:"
  log.notice "  $(stat -c '%n: mode=%a owner=%U group=%G' /run/docker 2>&1)"
  log.notice "  $(stat -c '%n: mode=%a owner=%U group=%G' /run/docker/containerd 2>&1)"
  log.notice "  $(stat -c '%n: mode=%a owner=%U group=%G' "$CONTAINERD_SOCK" 2>&1)"
  if [ -S "$CONTAINERD_SOCK" ] && [ -r "$CONTAINERD_SOCK" ] && [ -w "$CONTAINERD_SOCK" ]; then
    log.notice "containerd-direct path verified: runner user can read/write the socket; rules_img image_load will use it"
  else
    log.warning "socket perms applied but post-check failed (S=$([ -S "$CONTAINERD_SOCK" ] && echo y || echo n) r=$([ -r "$CONTAINERD_SOCK" ] && echo y || echo n) w=$([ -w "$CONTAINERD_SOCK" ] && echo y || echo n)); image_load may fall back to 'docker load'"
  fi
else
  log.warning "embedded containerd socket not found at $CONTAINERD_SOCK after ${CONTAINERD_SOCK_WAIT_S}s; image_load will fall back to 'docker load'"
  log.warning "  /run/docker contents (under sudo):"
  sudo ls -la /run/docker 2>&1 | sed 's/^/    /' || true
fi

if [ -n "${MTU}" ]; then
  sudo ifconfig docker0 mtu "${MTU}" up
fi

startup.sh
SCRIPT

RUNNER_INIT_PID=$!
log.notice "Runner init started with pid $RUNNER_INIT_PID"
wait $RUNNER_INIT_PID
log.notice "Runner init exited. Exiting this process with code 0 so that the container and the pod is GC'ed Kubernetes soon."

trap - TERM
