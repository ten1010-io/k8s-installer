"""The carrier of ec2: the vip as a secondary private address of the network
interface of the node that is MASTER.

A vpc delivers to the addresses it has on record for a network interface and
to nothing else, so the address keepalived raised has to be put on record too,
as a secondary private address of the interface of this node, and taken off the
one it was on. AssignPrivateIpAddresses with AllowReassignment does both in one
call, and that call is what carry() makes.

It runs on the host rather than in the keepalived container, because the call
needs the credentials of the instance and a request signer, and the container
holds neither and should be given neither. The credentials come from the
instance profile through the instance metadata, and so does everything else
this needs to know about the node: which network interface holds its address,
which subnet that interface is in, which region the api is in, and - for the
probe - which addresses the interface has on record, which is what the network
delivers to and needs no credentials to ask.

Nothing is ever unassigned. The address leaves an interface when the next
MASTER takes it, and a node taking it off itself on BACKUP would be two nodes
that disagree about who is MASTER each taking the address away from the other.

Standard library only, like every other python of this installer: the
interpreter is the one of the installer and nothing else is certain to be on a
node.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import ipaddress
import json
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass, field

IMDS_URL = "http://169.254.169.254"
# How long a token is asked for. Every run fetches its own, so it has to
# outlive one run and nothing more
IMDS_TOKEN_TTL_SECONDS = 300
EC2_API_VERSION = "2016-11-15"
EC2_SERVICE = "ec2"
# Per request. The metadata service answers in milliseconds and the api in
# well under a second, so this is the bound for one of them being gone
HTTP_TIMEOUT_SECONDS = 5.0
# The addresses a vpc keeps out of every subnet: the network address, the
# router, the resolver, one held for later, and the broadcast address
SUBNET_RESERVED_HEAD = 4
SUBNET_RESERVED_TAIL = 1


class CarrierError(Exception):
    """Something carry needed and did not get, in words an operator can act on."""


class ImdsError(CarrierError):
    pass


@dataclass
class Ec2Error(CarrierError):
    code: str
    message: str
    status: int

    def __str__(self) -> str:
        return f"{self.code}: {self.message}"


@dataclass
class Credentials:
    access_key_id: str
    secret_access_key: str
    session_token: str | None = None


@dataclass
class Interface:
    interface_id: str
    mac: str
    subnet_cidr: str
    local_ipv4s: list[str] = field(default_factory=list)


def add_arguments(parser: argparse.ArgumentParser) -> None:
    # Overridable for the tests, which stand a server up in place of each
    parser.add_argument("--imds-url", default=IMDS_URL, help=argparse.SUPPRESS)
    parser.add_argument("--ec2-url", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--timeout", type=float, default=HTTP_TIMEOUT_SECONDS, help=argparse.SUPPRESS)


def carry(args: argparse.Namespace) -> None:
    """One call. Whether it took is for the probe to say, and asking again is
    for the caller, which knows whether this node is still MASTER."""
    imds = Imds(args.imds_url, args.timeout)
    interface = imds.interface_holding(args.node_ip)
    if args.vip in interface.local_ipv4s:
        return
    ec2 = Ec2Client.from_imds(imds, args.ec2_url, args.timeout)
    ec2.assign_private_ip_address(interface.interface_id, args.vip)


def probe(args: argparse.Namespace) -> bool:
    imds = Imds(args.imds_url, args.timeout)
    return args.vip in imds.interface_holding(args.node_ip).local_ipv4s


def preflight(args: argparse.Namespace) -> list[str]:
    """Everything carry would need, asked without a single write.

    Each thing that is missing is reported with what to do about it, and all of
    them are reported rather than the first: the operator fixing an instance
    profile should not have to run this again to learn about the subnet.
    """
    imds = Imds(args.imds_url, args.timeout)
    errors: list[str] = []

    try:
        imds.token()
    except ImdsError as error:
        return [f"The instance metadata of ec2 does not answer at {args.imds_url}: {error}. The aws-eni carrier can"
                " only run on an ec2 instance, with the metadata service enabled"]

    interface = None
    try:
        interface = imds.interface_holding(args.node_ip)
    except ImdsError as error:
        errors.append(str(error))

    if interface is not None:
        errors.extend(vip_placement_errors(args.vip, interface))

    try:
        credentials = imds.credentials()
    except ImdsError as error:
        errors.append(
            f"{error}. The aws-eni carrier calls ec2:AssignPrivateIpAddresses with the credentials of the instance,"
            " so every ki cp node needs an instance profile whose role allows it")
        credentials = None

    # Not asked of an address the subnet can not hold: the api would refuse it
    # for that, and the refusal would be reported twice in different words
    if interface is not None and credentials is not None and not errors:
        errors.extend(dry_run_errors(imds, args, interface, credentials))

    return errors


def vip_placement_errors(vip: str, interface: Interface) -> list[str]:
    """Whether the subnet of this interface can hold the address at all."""
    try:
        subnet = ipaddress.ip_network(interface.subnet_cidr)
        address = ipaddress.ip_address(vip)
    except ValueError as error:
        return [f"Could not read the subnet of network interface[\"{interface.interface_id}\"] or the vip: {error}"]

    if address not in subnet:
        return [f"Vip[\"{vip}\"] is not in subnet[\"{subnet}\"] of network interface[\"{interface.interface_id}\"] of this node."
                " A secondary private address has to come from the subnet of the interface it goes on"]

    hosts = list(subnet)
    reserved = hosts[:SUBNET_RESERVED_HEAD] + hosts[len(hosts) - SUBNET_RESERVED_TAIL:]
    if address in reserved:
        return [f"Vip[\"{vip}\"] is one of the addresses aws keeps out of every subnet (the first four and the last one of"
                f" [\"{subnet}\"]). Pick another address of the subnet"]

    return []


def dry_run_errors(imds: Imds, args: argparse.Namespace, interface: Interface, credentials: Credentials) -> list[str]:
    """Asks the api to do nothing, which is how it says whether it would.

    DryRun answers DryRunOperation when the caller may and the parameters are
    right, and the real refusal otherwise, so one request tells the permission
    and the way to the api apart from each other and from a parameter the api
    would not take.
    """
    try:
        ec2 = Ec2Client.from_imds(imds, args.ec2_url, args.timeout, credentials)
        ec2.assign_private_ip_address(interface.interface_id, args.vip, dry_run=True)
    except Ec2Error as error:
        if error.code == "DryRunOperation":
            return []
        if error.code == "UnauthorizedOperation":
            return [f"The role of this instance may not call ec2:AssignPrivateIpAddresses on network interface"
                    f"[\"{interface.interface_id}\"]: {error.message}. Allow it in the policy of the instance profile"]
        return [f"ec2 refused to put vip[\"{args.vip}\"] on network interface[\"{interface.interface_id}\"]: {error}"]
    except CarrierError as error:
        return [f"{error}. The aws-eni carrier reaches the ec2 api at every vip handover, so the ki cp nodes need a"
                " route to it: a nat gateway, or an interface endpoint of the ec2 service in the vpc"]

    # A dry run that the api carried out is an api that did not understand it
    # was a dry run, which no ec2 does. Said rather than taken as a yes
    return [f"ec2 answered a dry run of AssignPrivateIpAddresses with success rather than DryRunOperation, which is not"
            f" an answer the aws-eni carrier knows how to read. Check what {args.ec2_url or 'the ec2 endpoint'} is"]


class Imds:
    """The instance metadata service, version 2 only."""

    def __init__(self, url: str, timeout: float):
        self.url = url.rstrip("/")
        self.timeout = timeout
        self._token: str | None = None

    def token(self) -> str:
        if self._token is None:
            request = urllib.request.Request(
                f"{self.url}/latest/api/token", method="PUT",
                headers={"X-aws-ec2-metadata-token-ttl-seconds": str(IMDS_TOKEN_TTL_SECONDS)})
            self._token = self._read(request, "a session token")
        return self._token

    def get(self, path: str) -> str:
        request = urllib.request.Request(
            f"{self.url}/latest/meta-data/{path}", headers={"X-aws-ec2-metadata-token": self.token()})
        return self._read(request, path)

    def _read(self, request: urllib.request.Request, what: str) -> str:
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            raise ImdsError(f"The instance metadata answered {error.code} for {what}") from error
        except (urllib.error.URLError, OSError) as error:
            raise ImdsError(f"The instance metadata could not be reached for {what}: {error}") from error

    def interfaces(self) -> list[Interface]:
        found = []
        for line in self.get("network/interfaces/macs/").splitlines():
            mac = line.strip().rstrip("/")
            if not mac:
                continue
            prefix = f"network/interfaces/macs/{mac}"
            found.append(Interface(
                interface_id=self.get(f"{prefix}/interface-id").strip(),
                mac=mac,
                subnet_cidr=self.get(f"{prefix}/subnet-ipv4-cidr-block").strip(),
                local_ipv4s=[ip.strip() for ip in self.get(f"{prefix}/local-ipv4s").splitlines() if ip.strip()]))
        return found

    def interface_holding(self, ip: str) -> Interface:
        """The network interface whose addresses include this one.

        Named by the address of the node rather than taken to be the first
        interface, so that an instance with more than one is carried on the
        one the cluster is reached through. The vip is a secondary address of
        the same interface, which is why keepalived raises it there.
        """
        interfaces = self.interfaces()
        for interface in interfaces:
            if ip in interface.local_ipv4s:
                return interface
        names = ", ".join(interface.interface_id for interface in interfaces) or "none"
        raise ImdsError(f"No network interface of this instance holds address[\"{ip}\"] (interfaces: {names})")

    def region(self) -> str:
        return self.get("placement/region").strip()

    def credentials(self) -> Credentials:
        try:
            roles = self.get("iam/security-credentials/").split()
        except ImdsError as error:
            raise ImdsError("This instance has no instance profile") from error
        if not roles:
            raise ImdsError("This instance has no instance profile")

        document = json.loads(self.get(f"iam/security-credentials/{roles[0]}"))
        if document.get("Code", "Success") != "Success" or "AccessKeyId" not in document:
            raise ImdsError(f"The credentials of role[\"{roles[0]}\"] could not be read: {document.get('Message', document)}")
        return Credentials(document["AccessKeyId"], document["SecretAccessKey"], document.get("Token"))


class Ec2Client:
    """As much of the ec2 query api as carrying an address takes: one action,
    signed by hand, because the sdk is not on a node and this is all it would
    be used for."""

    def __init__(self, url: str, region: str, credentials: Credentials, timeout: float):
        self.url = url
        self.region = region
        self.credentials = credentials
        self.timeout = timeout

    @classmethod
    def from_imds(cls, imds: Imds, url: str | None, timeout: float, credentials: Credentials | None = None) -> Ec2Client:
        region = imds.region()
        return cls(url or f"https://ec2.{region}.amazonaws.com/", region, credentials or imds.credentials(), timeout)

    def assign_private_ip_address(self, interface_id: str, ip: str, dry_run: bool = False) -> None:
        parameters = {
            "Action": "AssignPrivateIpAddresses",
            "Version": EC2_API_VERSION,
            "NetworkInterfaceId": interface_id,
            "PrivateIpAddress.1": ip,
            # What takes the address off the interface it is on. Without it the
            # api refuses an address another interface holds, and the whole
            # point is that it does
            "AllowReassignment": "true",
        }
        if dry_run:
            parameters["DryRun"] = "true"
        self.call(parameters)

    def call(self, parameters: dict[str, str]) -> str:
        body = urllib.parse.urlencode(sorted(parameters.items())).encode("utf-8")
        headers = {"Content-Type": "application/x-www-form-urlencoded; charset=utf-8"}
        headers = sign_v4("POST", self.url, headers, body, self.region, EC2_SERVICE, self.credentials)
        request = urllib.request.Request(self.url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            raise parse_ec2_error(error.code, error.read().decode("utf-8", "replace")) from error
        except (urllib.error.URLError, OSError) as error:
            raise CarrierError(f"The ec2 api at {self.url} could not be reached: {error}") from error


def parse_ec2_error(status: int, body: str) -> Ec2Error:
    """The code and message of an error response, which is xml, or the body
    as it came when it is not: a proxy in the way answers in its own words."""
    try:
        root = ElementTree.fromstring(body)
        error = root.find(".//Error")
        if error is not None:
            return Ec2Error(error.findtext("Code", "").strip(), error.findtext("Message", "").strip(), status)
    except ElementTree.ParseError:
        pass
    return Ec2Error(f"HTTP {status}", body.strip()[:500], status)


def sign_v4(method: str, url: str, headers: dict[str, str], body: bytes, region: str, service: str,
            credentials: Credentials, now: datetime.datetime | None = None) -> dict[str, str]:
    """Signature version 4, over the headers given plus the three it adds.

    Written here rather than taken from a library for the same reason the
    whole module is standard library. The shape is the one aws documents: a
    canonical request, hashed into a string to sign, signed with a key derived
    from the secret through the date, region and service.
    """
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date = now.strftime("%Y%m%d")

    parts = urllib.parse.urlsplit(url)
    signed = {key.lower(): " ".join(value.split()) for key, value in headers.items()}
    signed["host"] = parts.netloc
    signed["x-amz-date"] = amz_date
    if credentials.session_token:
        signed["x-amz-security-token"] = credentials.session_token

    canonical_headers = "".join(f"{key}:{signed[key]}\n" for key in sorted(signed))
    signed_headers = ";".join(sorted(signed))
    canonical_query = urllib.parse.urlencode(sorted(urllib.parse.parse_qsl(parts.query, keep_blank_values=True)))
    canonical_request = "\n".join([
        method.upper(),
        urllib.parse.quote(parts.path or "/", safe="/~"),
        canonical_query,
        canonical_headers,
        signed_headers,
        hashlib.sha256(body).hexdigest(),
    ])

    scope = f"{date}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256",
        amz_date,
        scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])

    key = f"AWS4{credentials.secret_access_key}".encode("utf-8")
    for piece in (date, region, service, "aws4_request"):
        key = hmac.new(key, piece.encode("utf-8"), hashlib.sha256).digest()
    signature = hmac.new(key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    result = dict(headers)
    result["Host"] = parts.netloc
    result["X-Amz-Date"] = amz_date
    if credentials.session_token:
        result["X-Amz-Security-Token"] = credentials.session_token
    result["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={credentials.access_key_id}/{scope},"
        f" SignedHeaders={signed_headers}, Signature={signature}")
    return result
