#!/usr/bin/env bash
root_path="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

if [ -e $root_path/bin ]; then
  if [ -d $root_path/bin ]; then
    echo "error: Directory \"bin\" already exist"
    exit 1
  fi
  echo "error: File of which name is \"bin\" exist. delete the file first"
  exit 1
fi

DOWNLOAD_URL="https://k8s-installer-bin.s3.ap-northeast-2.amazonaws.com/1.0.x/bin.tgz"
HAS_CURL="$(type "curl" &>/dev/null && echo true || echo false)"
HAS_WGET="$(type "wget" &>/dev/null && echo true || echo false)"

if [ "${HAS_CURL}" == "true" ]; then
  curl -L "$DOWNLOAD_URL" -o "$root_path/bin.tgz"
elif [ "${HAS_WGET}" == "true" ]; then
  wget -O "$root_path/bin.tgz" "$DOWNLOAD_URL"
else
  echo "error: Fail to download bin.tgz. either curl or wget must be installed"
  exit 1
fi

tar xzfv $root_path/bin.tgz --directory $root_path
rm -f $root_path/bin.tgz
