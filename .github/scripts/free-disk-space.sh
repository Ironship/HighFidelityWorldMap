#!/usr/bin/env bash
# The map art tree is ~7 GB. The packager then copies it into .release/ and
# zips that, so a stock runner's ~14 GB runs out partway through the zip.
# Everything removed here is preinstalled tooling the job never touches.
#
# Deleting ~27 GB of small files takes about 2 minutes, so it can run in the
# background while the (network-bound) cache restore downloads:
#   free-disk-space.sh start   begin deleting, return immediately
#   free-disk-space.sh wait    block until the deletion has finished
#   free-disk-space.sh         both, in order
set -euo pipefail

done_file=/tmp/free-disk-space.done

start() {
  rm -f "$done_file"
  df -h / | tail -n1
  # ponytail: serial rm; the 2 min measured on ubuntu-latest was serial. Try parallel only if measured faster.
  setsid nohup bash -c '
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
      /usr/local/.ghcup /opt/hostedtoolcache/CodeQL /usr/local/share/boost \
      /usr/share/swift
    sudo docker image prune --all --force >/dev/null 2>&1 || true
    touch '"$done_file"'
  ' >/dev/null 2>&1 &
}

wait_done() {
  until [[ -e "$done_file" ]]; do sleep 2; done
  df -h / | tail -n1
}

case "${1:-both}" in
  start) start ;;
  wait) wait_done ;;
  both) start; wait_done ;;
  *) echo "usage: $0 [start|wait]" >&2; exit 2 ;;
esac
