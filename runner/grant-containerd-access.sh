#!/bin/bash
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
#
# Invoked from both entrypoint-dind.sh and from the init container's args
# in the kube manifests; keep the logic in one place so the two callsites
# can't drift.

set -u

CONTAINERD_SOCK=${CONTAINERD_SOCK:-/run/docker/containerd/containerd.sock}
CONTAINERD_SOCK_WAIT_S=${CONTAINERD_SOCK_WAIT_S:-30}
DOCKER_GROUP=${DOCKER_GROUP:-docker}

# Use the image's logger when available so output blends in with the rest of
# the entrypoint; fall back to printf for callers that don't source logger.sh
# (e.g. a bare init container).
if [ -r /usr/bin/logger.sh ]; then
  # shellcheck source=/dev/null
  source /usr/bin/logger.sh
elif [ -r /usr/local/bin/logger.sh ]; then
  # shellcheck source=/dev/null
  source /usr/local/bin/logger.sh
fi
if ! declare -F log.notice >/dev/null; then
  log.notice()  { printf '[grant-containerd-access] NOTICE  --- %s\n' "$*" 1>&2; }
  log.warning() { printf '[grant-containerd-access] WARNING --- %s\n' "$*" 1>&2; }
fi

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
  log.notice "containerd socket appeared after $(printf '%d.%01d' $((sock_found_iter / 10)) $((sock_found_iter % 10)))s; granting ${DOCKER_GROUP}-group access"
  sudo chgrp "$DOCKER_GROUP" /run/docker /run/docker/containerd "$CONTAINERD_SOCK"
  sudo chmod g+rx /run/docker /run/docker/containerd
  sudo chmod 660 "$CONTAINERD_SOCK"
  log.notice "post-chmod perms:"
  log.notice "  $(stat -c '%n: mode=%a owner=%U group=%G' /run/docker 2>&1)"
  log.notice "  $(stat -c '%n: mode=%a owner=%U group=%G' /run/docker/containerd 2>&1)"
  log.notice "  $(stat -c '%n: mode=%a owner=%U group=%G' "$CONTAINERD_SOCK" 2>&1)"
  if [ -S "$CONTAINERD_SOCK" ] && [ -r "$CONTAINERD_SOCK" ] && [ -w "$CONTAINERD_SOCK" ]; then
    log.notice "containerd-direct path verified: current user can read/write the socket; rules_img image_load will use it"
  else
    log.warning "socket perms applied but post-check failed (S=$([ -S "$CONTAINERD_SOCK" ] && echo y || echo n) r=$([ -r "$CONTAINERD_SOCK" ] && echo y || echo n) w=$([ -w "$CONTAINERD_SOCK" ] && echo y || echo n)); image_load may fall back to 'docker load'"
  fi
else
  log.warning "embedded containerd socket not found at $CONTAINERD_SOCK after ${CONTAINERD_SOCK_WAIT_S}s; image_load will fall back to 'docker load'"
  log.warning "  /run/docker contents (under sudo):"
  sudo ls -la /run/docker 2>&1 | sed 's/^/    /' || true
fi
