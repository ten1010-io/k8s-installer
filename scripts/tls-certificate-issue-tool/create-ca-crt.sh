#!/usr/bin/env bash
script_path="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
output_path=$script_path/output

days=3650

function parse_options() {
  VALID_ARGS=$(getopt -o h --long common-name:,days: -- "$@")
  if [ $? -ne 0 ]; then
    echo "error: Fail to parse options" >&2; exit 1
  fi
  eval set -- "$VALID_ARGS"
  while [ : ]; do
    case "$1" in
    --common-name)
      common_name=$2
      shift 2
      ;;
    --days)
      re='^[0-9]+$'
      if ! [[ $2 =~ $re ]] ; then
         echo "Error : --days option value must be number" >&2; exit 1
      fi
      days=$2
      shift 2
      ;;
    -h)
      echo "usage: $(basename $0) [--common-name(required)] [--days(optional)]" >&2; exit 1
      ;;
    --)
      shift
      break
      ;;
    esac
  done
}

parse_options "$@"

mkdir -p "$output_path"
if [ -e "$output_path/ca.crt" ]; then
  echo "Error : File [$output_path/ca.crt] already exist" >&2; exit 1
fi
if [ -z $common_name ]; then
  echo "Error : Common name for certificate must be provided" >&2; exit 1
fi
if ! cp "${script_path}/ca.conf" "$output_path"; then
  echo "Error : Writing file failed" >&2; exit 1
fi
if ! sed -i 's/CN =/''CN = '"$common_name"'/g' "${output_path}/ca.conf"; then
  echo "Error : Writing file failed" >&2; exit 1
fi

openssl req -config "${output_path}/ca.conf" -newkey rsa -x509 -days $days -keyout "${output_path}/ca.key" -out "${output_path}/ca.crt" -set_serial 0
