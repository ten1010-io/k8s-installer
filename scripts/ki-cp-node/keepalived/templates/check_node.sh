#!/bin/sh

msg() {
  echo >&2 "${1-}"
}

die() {
  msg=$1
  code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

curl --silent -XGET --unix-socket /run/docker.sock http://localhost/_ping || die "[ERROR] Ping test for Docker failed"
