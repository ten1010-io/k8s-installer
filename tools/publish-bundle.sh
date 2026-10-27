#!/usr/bin/env bash

SCRIPT_DIR_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

print_usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--bundle-path path] [--bucket name] [--key-prefix prefix]
       [--region region] [--replace] [--presigned-url url | --make-presigned-url [--expires-in seconds]]
Available options:
-h, --help      Print this help and exit
-v, --verbose   Print script debug info
--bundle-path   The archive to publish, defaults to bundle-<version>.tgz beside this tree
--bucket        The bucket, defaults to k8s-installer-bundle, which download-bundle.sh reads
--key-prefix    Put the object under this prefix instead of at the root of the bucket, such as
                test/ for a trial upload. download-bundle.sh reads the root
--region        The region of the bucket, defaults to ap-northeast-2
--replace       Overwrite the snapshot bundle already published under this name. A release bundle
                is never overwritten, with or without this
--presigned-url Upload through this PUT url instead of with the credentials of this machine
--make-presigned-url
                Print a PUT url for the object and stop, after the checks a publish makes. For when
                the machine that holds the archive has no credentials: run this where they are, and
                --presigned-url there
--expires-in    How many seconds the url of --make-presigned-url is good for, defaults to 3600
EOF
  exit
}

parse_params() {
  bundle_path=""
  bucket="k8s-installer-bundle"
  key_prefix=""
  region="ap-northeast-2"
  replace="false"
  presigned_url=""
  make_presigned_url="false"
  expires_in="3600"

  while :; do
    case "${1-}" in
    -h | --help) print_usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --bundle-path)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      bundle_path="${2-}"
      shift
      ;;
    --bucket)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      bucket="${2-}"
      shift
      ;;
    --key-prefix)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      key_prefix="${2-}"
      shift
      ;;
    --region)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      region="${2-}"
      shift
      ;;
    --replace) replace="true" ;;
    --presigned-url)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      presigned_url="${2-}"
      shift
      ;;
    --make-presigned-url) make_presigned_url="true" ;;
    --expires-in)
      [[ -z "${2-}" ]] && die "[ERROR] Missing required value for option: ${1-}"
      expires_in="${2-}"
      shift
      ;;
    -?*) die "[ERROR] Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ -n $presigned_url && $make_presigned_url = "true" ]] &&
    die "[ERROR] Options --presigned-url and --make-presigned-url are for the two ends of one upload. pass one"
  [[ $expires_in =~ ^[0-9]+$ ]] || die "[ERROR] Option --expires-in takes a number of seconds"

  return 0
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  [[ -n ${work_path-} ]] && rm -rf "$work_path"

  return 0
}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
setup_colors
parse_params "$@"

# --- End of CLI template ---

# Puts the archive assemble-bundle.sh made where download-bundle.sh reads it,
# as the object bundle-<version>.tgz of the bucket, and refuses the uploads the
# release scheme forbids.
#
# A release bundle is published once and never rebuilt, so an object already
# there under the name of a release is refused whatever the caller says, and
# the upload itself is made conditional on the key not existing, so that two
# people publishing the same release at once can not both succeed. A snapshot
# is republished under its name as often as development needs, but the bucket
# keeps no versions, so what is there is shown and --replace has to say that
# overwriting it is meant. The archive of a release also has to be the one
# release.yml records the sha256 of: the number in the repository is what every
# control node checks the download against, and publishing anything else is
# publishing a bundle nobody can install.
#
# The upload is one PUT rather than a multipart transfer, so that the ETag the
# bucket reports is the md5 of the object and the upload can be checked against
# the file without downloading it again. That holds up to 5G, and the bundle is
# about half of that.
#
# A machine that holds the archive need not hold credentials. Run this with
# --make-presigned-url where the credentials are, which makes the checks above
# and prints a url, and with --presigned-url where the archive is. The url
# carries the condition on the key, so the end that uploads can not publish a
# release over one that appeared in between
KI_ROOT_PATH=$(cd "$SCRIPT_DIR_PATH/.." &>/dev/null && pwd -P)
RELEASE_META_PATH="$KI_ROOT_PATH"/release.yml

# Kept in step with the ones download-bundle.sh carries
SNAPSHOT_SUFFIX="-SNAPSHOT"

work_path=""
version=""
is_release="false"
key=""
object_url=""

main() {
  [[ -f $RELEASE_META_PATH ]] || die "[ERROR] No such file or directory of which path is \"$RELEASE_META_PATH\""

  version=$(grep -oP '^version: "\K[^"]+' < "$RELEASE_META_PATH")
  [[ -z $version ]] && die "[ERROR] File[\"$RELEASE_META_PATH\"] has no version"
  [[ $version == *"$SNAPSHOT_SUFFIX" ]] || is_release="true"
  [[ $is_release = "true" && $replace = "true" ]] &&
    die "[ERROR] Release[\"$version\"] is not a snapshot. a release bundle is published once and never overwritten, so --replace does not apply"

  key="$key_prefix$(bundle_name)"
  object_url="https://$bucket.s3.$region.amazonaws.com/$key"
  [[ -z $bundle_path ]] && bundle_path="$KI_ROOT_PATH/$(bundle_name)"

  if [[ $make_presigned_url = "true" ]]; then
    make_presigned_url
    return 0
  fi

  require_bundle_archive

  work_path=$(mktemp -d)
  local size md5
  size=$(stat -c %s "$bundle_path")
  md5=$(md5sum "$bundle_path" | cut -d' ' -f1)

  if [[ -n $presigned_url ]]; then
    upload_with_presigned_url
  else
    require_command aws
    refuse_what_the_bucket_holds
    upload_with_credentials
  fi

  verify_object "$size" "$md5"
  report_public_read

  return 0
}

bundle_name() {
  echo "bundle-$version.tgz"
}

require_command() {
  local command=$1

  type "$command" &>/dev/null && return 0

  die "[ERROR] Command[\"$command\"] is needed and not installed"
}

# The archive is named after the release so that the object is: a file of
# another name is the bundle of another release, or not a bundle at all. A
# release bundle also has to be the one release.yml names, since that is the
# only bundle a control node will install
require_bundle_archive() {
  [[ -f $bundle_path ]] || die "[ERROR] File[\"$bundle_path\"] not exists. assemble-bundle.sh makes it"
  [[ $(basename "$bundle_path") = "$(bundle_name)" ]] ||
    die "[ERROR] File[\"$bundle_path\"] is not named $(bundle_name), which is the bundle of release[\"$version\"] and the object this publishes"

  [[ $is_release = "true" ]] || return 0

  local recorded actual
  recorded=$(grep -oP '^bundle_sha256: "\K[^"]*' < "$RELEASE_META_PATH" || true)
  [[ -z $recorded ]] &&
    die "[ERROR] File[\"$RELEASE_META_PATH\"] records no bundle_sha256 for release[\"$version\"]. assemble-bundle.sh --write-sha256 records it, and it is committed with the release before the bundle is published"
  actual=$(sha256sum "$bundle_path" | cut -d' ' -f1)
  [[ $actual = "$recorded" ]] ||
    die "[ERROR] File[\"$bundle_path\"] has sha256[\"$actual\"] and release.yml records sha256[\"$recorded\"] for release[\"$version\"]. a control node would refuse this archive, so it is not published"

  msg "[INFO] File[\"$bundle_path\"] is the bundle release.yml records for release[\"$version\"]"

  return 0
}

# What is already under the key decides whether this may go on at all. A
# release found there is final. A snapshot found there is shown, since the
# bucket keeps no versions and more than one person republishes the snapshot,
# and it is replaced only when asked
refuse_what_the_bucket_holds() {
  local head
  if ! head=$(aws s3api head-object --bucket "$bucket" --key "$key" --query '[ContentLength,ETag,LastModified]' --output text 2>&1 | tr -d '\r'); then
    grep -q "Not Found\|404" <<< "$head" && return 0
    die "[ERROR] Fail to ask bucket[\"$bucket\"] about key[\"$key\"]:\n$head"
  fi

  local size etag modified
  read -r size etag modified <<< "$head"
  if [[ $is_release = "true" ]]; then
    msg "[ERROR] Bucket[\"$bucket\"] already holds key[\"$key\"]: $size bytes, ETag $etag, published $modified"
    die "[ERROR] A release bundle is published once and never rebuilt. if release[\"$version\"] has to carry something else, it is the next release"
  fi

  msg "[INFO] Bucket[\"$bucket\"] already holds key[\"$key\"]: $size bytes, ETag $etag, published $modified"
  [[ $replace = "true" ]] ||
    die "[ERROR] Pass --replace to overwrite it. the bucket keeps no versions, so what is there is gone once this goes up"

  msg "[INFO] Replacing it, as asked"

  return 0
}

# One PUT, see above. The condition on a release makes the refusal above
# hold against an upload that lands between that check and this one
upload_with_credentials() {
  local opts=()
  [[ $is_release = "true" ]] && opts+=(--if-none-match '*')

  msg "[INFO] Uploading $(du -h "$bundle_path" | cut -f1) to \"$object_url\""
  aws s3api put-object --bucket "$bucket" --key "$key" --body "$bundle_path" "${opts[@]}" > "$work_path/put.json" ||
    die "[ERROR] Fail to upload \"$bundle_path\" to \"$object_url\""

  return 0
}

# The url says which object it was made for, and the object it was made for
# has to be this one. The condition a release url was signed with has to be
# sent along, since the signature covers it
upload_with_presigned_url() {
  require_command curl

  [[ $presigned_url = "https://$bucket."*"/$key?"* ]] ||
    die "[ERROR] The presigned url is not for key[\"$key\"] of bucket[\"$bucket\"], which is what release[\"$version\"] publishes. make it with --make-presigned-url and the same --bucket and --key-prefix"

  local opts=()
  [[ $is_release = "true" ]] && opts+=(-H 'If-None-Match: *')

  msg "[INFO] Uploading $(du -h "$bundle_path" | cut -f1) to \"$object_url\" through the presigned url"
  local status
  status=$(curl -sS -o "$work_path/put.body" -D "$work_path/put.headers" -w '%{http_code}' -T "$bundle_path" "${opts[@]}" "$presigned_url") ||
    die "[ERROR] Fail to upload \"$bundle_path\" through the presigned url"
  [[ $status = 200 ]] ||
    die "[ERROR] The bucket answered the upload with http $status:\n$(cat "$work_path/put.body")"

  return 0
}

# A single PUT leaves the md5 of the object as its ETag, so the object is
# compared with the file from what the bucket says about it, and without
# credentials from what it said in the answer to the PUT
verify_object() {
  local size=$1 md5=$2

  local etag="" found_size=""
  if [[ -n $presigned_url ]]; then
    etag=$(grep -i '^etag:' "$work_path/put.headers" | tr -d '\r"' | awk '{print $2}')
    found_size=$size
  else
    read -r found_size etag < <(aws s3api head-object --bucket "$bucket" --key "$key" --query '[ContentLength,ETag]' --output text | tr -d '\r"')
  fi

  [[ $etag = "$md5" && $found_size = "$size" ]] && {
    msg "[INFO] Published \"$object_url\": $size bytes, md5 $md5, as the file here"
    return 0
  }

  msg "[ERROR] The object at \"$object_url\" is $found_size bytes with ETag $etag, and the file here is $size bytes with md5 $md5"
  die "[ERROR] The upload did not arrive as it left. it is there under that key, so publish again"
}

# download-bundle.sh reads the object anonymously, and whether it may is the
# policy of the bucket, which this does not touch. It is asked once, the way
# a control node would ask, so that a release published behind a policy that
# names only the keys before it is noticed here and not by the first customer
report_public_read() {
  local status
  status=$(curl -s -o /dev/null -I -w '%{http_code}' "$object_url" || true)

  if [[ $status = 200 ]]; then
    if [[ -z $key_prefix && $bucket = "k8s-installer-bundle" ]]; then
      msg "[INFO] download-bundle.sh reads it from there"
    else
      msg "[INFO] It is readable without credentials. KI_BUNDLE_BASE_URL=https://$bucket.s3.$region.amazonaws.com/${key_prefix%/} has download-bundle.sh read it"
    fi
    return 0
  fi

  msg "[WARN] An anonymous GET of \"$object_url\" answers http $status, so download-bundle.sh can not read it"
  msg "[WARN] The policy of bucket[\"$bucket\"] names the keys it allows s3:GetObject on. a resource of arn:aws:s3:::$bucket/bundle-*.tgz covers every bundle at the root; a trial upload under a prefix is expected to stay private"

  return 0
}

# A PUT url for the key, signed here with the credentials of this machine so
# that a machine without any can upload. The regional endpoint, s3v4 and
# virtual addressing are what makes the url the bucket accepts rather than
# one it answers with a redirect to, which curl -T does not follow with the
# body. The refusals of a publish are made here, since the other end can not
# ask the bucket anything, and a release url is signed with the condition
# that the key does not exist, so that the other end can not publish a
# release over one that appeared in between
make_presigned_url() {
  require_command aws
  local python
  python=$(find_python_with_boto3) || die "[ERROR] A python with boto3 is needed to sign the url and none was found"

  refuse_what_the_bucket_holds

  local url
  url=$("$python" - "$bucket" "$key" "$region" "$expires_in" "$is_release" <<'PY'
import sys
import boto3
from botocore.config import Config

bucket, key, region, expires_in, is_release = sys.argv[1:6]
client = boto3.client(
    "s3",
    region_name=region,
    endpoint_url=f"https://s3.{region}.amazonaws.com",
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
)
params = {"Bucket": bucket, "Key": key}
if is_release == "true":
    params["IfNoneMatch"] = "*"
print(client.generate_presigned_url("put_object", Params=params, ExpiresIn=int(expires_in), HttpMethod="PUT"))
PY
  ) || die "[ERROR] Fail to sign a url for key[\"$key\"] of bucket[\"$bucket\"]"

  msg "[INFO] A PUT url for \"$object_url\", good for $expires_in seconds. on the machine that holds the archive:"
  msg "[INFO]   tools/publish-bundle.sh --presigned-url '<the url below>'${key_prefix:+ --key-prefix $key_prefix}$([[ $bucket != "k8s-installer-bundle" ]] && echo " --bucket $bucket")"
  echo "$url"

  return 0
}

find_python_with_boto3() {
  local python
  for python in python3 python; do
    "$python" -c 'import boto3' &>/dev/null || continue
    echo "$python"
    return 0
  done

  return 1
}

main
