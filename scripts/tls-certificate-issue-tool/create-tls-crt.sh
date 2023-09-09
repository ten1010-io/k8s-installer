#!/usr/bin/env bash
script_path="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
output_path=$script_path/output

days=365

function parse_options() {
  VALID_ARGS=$(getopt -o h --long domain-name:,days: -- "$@")
  if [ $? -ne 0 ]; then
    echo "error: Fail to parse options" >&2; exit 1
  fi
  eval set -- "$VALID_ARGS"
  while [ : ]; do
    case "$1" in
    --domain-name)
      if ! echo $2 | grep -P '([a-z0-9A-Z]\.)*[a-z0-9-]+\.([a-z0-9]{2,24})+(\.co\.([a-z0-9]{2,24})|\.([a-z0-9]{2,24}))*'; then
        echo "Error : Invalid domain name provided" >&2; exit 1
      fi
      domain_name=$2
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
      echo "usage: $(basename $0) [--domain-name(required)] [--days(optional)]" >&2; exit 1
      ;;
    --)
      shift
      break
      ;;
    esac
  done
}

parse_options "$@"
if [ -z $domain_name ]; then
  echo "Error : Domain name for tls certificate must be provided" >&2; exit 1
fi

mkdir -p ${output_path}/$domain_name
if [ ! -f "$output_path/ca.crt" ]; then
  echo "Error : File [$output_path/ca.crt] not exist" >&2; exit 1
fi
if [ -e "${output_path}/$domain_name/tls.crt" ]; then
  echo "Error : File [${output_path}/$domain_name/tls.crt] already exist" >&2; exit 1
fi
if ! cp "${script_path}/tls.conf" "${output_path}/$domain_name"; then
  echo "Error : Writing file failed" >&2; exit 1
fi
if ! cp "${script_path}/tls.ext" "${output_path}/$domain_name"; then
  echo "Error : Writing file failed" >&2; exit 1
fi
if ! sed -i 's/CN =/''CN = '"$domain_name"'/g' "${output_path}/$domain_name/tls.conf"; then
  echo "Error : Writing file failed" >&2; exit 1
fi
if ! sed -i 's/DNS.1 =/''DNS.1 = '"$domain_name"'/g' "${output_path}/$domain_name/tls.ext"; then
  echo "Error : Writing file failed" >&2; exit 1
fi

openssl req -newkey rsa -config "${output_path}/$domain_name/tls.conf" -keyout "${output_path}/$domain_name/tls.key" -out "${output_path}/$domain_name/tls.csr"
openssl x509 -req -CA "${output_path}/ca.crt" -CAkey "${output_path}/ca.key" -CAserial "${output_path}/.srl" -CAcreateserial -in "${output_path}/$domain_name/tls.csr" -extfile "${output_path}/$domain_name/tls.ext" -out "${output_path}/$domain_name/tls.crt" -days $days
