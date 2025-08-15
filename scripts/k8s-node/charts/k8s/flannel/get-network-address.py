#!/usr/bin/env python3
import argparse
import ipaddress

parser = argparse.ArgumentParser()
parser.add_argument("cidr")
args = parser.parse_args()

cidr = ipaddress.ip_network(args.cidr)
print(str(cidr.network_address))

exit(0)
