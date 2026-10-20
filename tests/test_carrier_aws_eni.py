"""What the aws-eni carrier is for is one api call, made when the node is
MASTER and the address is not yet on its interface, and not made otherwise.

The carrier is run as the unit runs it, through carry-vip.py as a process,
against an instance metadata service and an ec2 api that are stood up here,
so that what is asserted is the contract the unit and check-node-state.sh
depend on: the exit code, what was asked of the api, and that the report
names what to fix.
"""
from __future__ import annotations

import datetime
import importlib.util
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

KEEPALIVED = Path(__file__).resolve().parents[1] / "scripts" / "ki-cp-node" / "keepalived"
SCRIPT = KEEPALIVED / "carry-vip.py"
CARRIER = KEEPALIVED / "carriers" / "aws_eni.py"

NODE_IP = "172.31.50.11"
PEER_IP = "172.31.50.12"
VIP = "172.31.50.10"
SUBNET = "172.31.48.0/20"
NODE_ENI = "eni-0node"
PEER_ENI = "eni-0peer"
ROLE = "ki-cp-node"
ACCESS_KEY = "ASIAEXAMPLE"
SECRET_KEY = "secret"
SESSION_TOKEN = "session-token"


def load_module():
    spec = importlib.util.spec_from_file_location("carrier_aws_eni", CARRIER)
    module = importlib.util.module_from_spec(spec)
    # Registered before it runs: the dataclasses of the module carry string
    # annotations, which dataclasses resolves through sys.modules
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Cloud:
    """The two services the carrier talks to, with the state they share: which
    interface holds which addresses."""

    def __init__(self):
        self.interfaces = {
            NODE_ENI: {"mac": "0a:00:00:00:00:01", "ips": [NODE_IP]},
            PEER_ENI: {"mac": "0a:00:00:00:00:02", "ips": [PEER_IP, VIP]},
        }
        self.has_role = True
        self.fail_times = 0
        self.unauthorized = False
        self.calls: list[dict[str, str]] = []
        self.servers: list[ThreadingHTTPServer] = []

    def start(self):
        cloud = self

        class ImdsHandler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_PUT(self):
                if self.path == "/latest/api/token":
                    self.answer(200, "token")
                else:
                    self.answer(404, "")

            def do_GET(self):
                if self.headers.get("X-aws-ec2-metadata-token") != "token":
                    self.answer(401, "")
                    return
                self.answer(*cloud.metadata(self.path))

            def answer(self, status, body):
                data = body.encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        class Ec2Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                parameters = dict(urllib.parse.parse_qsl(self.rfile.read(length).decode("utf-8")))
                parameters["_authorization"] = self.headers.get("Authorization", "")
                parameters["_token"] = self.headers.get("X-Amz-Security-Token", "")
                cloud.calls.append(parameters)
                status, body = cloud.ec2(parameters)
                data = body.encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.imds_url = self.serve(ImdsHandler)
        self.ec2_url = self.serve(Ec2Handler)
        return self

    def serve(self, handler) -> str:
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.servers.append(server)
        return f"http://127.0.0.1:{server.server_address[1]}/"

    def stop(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()

    def metadata(self, path: str):
        prefix = "/latest/meta-data/"
        if not path.startswith(prefix):
            return 404, ""
        path = path[len(prefix):]

        if path == "placement/region":
            return 200, "ap-northeast-2"
        if path == "iam/security-credentials/":
            return (200, ROLE) if self.has_role else (404, "")
        if path == f"iam/security-credentials/{ROLE}" and self.has_role:
            return 200, (f'{{"Code": "Success", "AccessKeyId": "{ACCESS_KEY}", "SecretAccessKey": "{SECRET_KEY}",'
                         f' "Token": "{SESSION_TOKEN}"}}')
        if path == "network/interfaces/macs/":
            return 200, "".join(f"{entry['mac']}/\n" for entry in self.interfaces.values())
        for interface_id, entry in self.interfaces.items():
            head = f"network/interfaces/macs/{entry['mac']}/"
            if path == head + "interface-id":
                return 200, interface_id
            if path == head + "subnet-ipv4-cidr-block":
                return 200, SUBNET
            if path == head + "local-ipv4s":
                return 200, "\n".join(entry["ips"])
        return 404, ""

    def ec2(self, parameters: dict[str, str]):
        if parameters.get("Action") != "AssignPrivateIpAddresses":
            return 400, error_xml("InvalidAction", "unknown")
        if self.unauthorized:
            return 403, error_xml("UnauthorizedOperation", "You are not authorized to perform this operation")
        if self.fail_times > 0:
            self.fail_times -= 1
            return 500, error_xml("InternalError", "An internal error has occurred")
        if parameters.get("DryRun") == "true":
            return 412, error_xml("DryRunOperation", "Request would have succeeded, but DryRun flag is set")

        ip = parameters["PrivateIpAddress.1"]
        target = parameters["NetworkInterfaceId"]
        for interface_id, entry in self.interfaces.items():
            if ip in entry["ips"] and interface_id != target:
                if parameters.get("AllowReassignment") != "true":
                    return 400, error_xml("InvalidParameterValue", f"Address {ip} is in use")
                entry["ips"].remove(ip)
        self.interfaces[target]["ips"].append(ip)
        return 200, "<AssignPrivateIpAddressesResponse><return>true</return></AssignPrivateIpAddressesResponse>"


def error_xml(code: str, message: str) -> str:
    return f"<Response><Errors><Error><Code>{code}</Code><Message>{message}</Message></Error></Errors></Response>"


@pytest.fixture
def cloud():
    cloud = Cloud().start()
    yield cloud
    cloud.stop()


@pytest.fixture
def state_path(tmp_path):
    return tmp_path / "vrrp"


def run(cloud: Cloud, verb: str, *args: str, vip: str = VIP) -> subprocess.CompletedProcess:
    command = [sys.executable, str(SCRIPT), "--carrier", "aws-eni", verb,
               "--vip", vip, "--node-ip", NODE_IP,
               "--imds-url", cloud.imds_url, "--ec2-url", cloud.ec2_url, "--timeout", "2", *args]
    return subprocess.run(command, capture_output=True, text=True, timeout=60)


def run_reconcile(cloud: Cloud, state_path: Path) -> subprocess.CompletedProcess:
    return run(cloud, "reconcile", "--state-path", str(state_path),
               "--carried-path", str(state_path.parent / "carried"),
               "--pending-path", str(state_path.parent / "pending"),
               "--confirm-seconds", "2")


def test_a_node_that_is_not_master_asks_the_api_nothing(cloud, state_path):
    state_path.write_text("BACKUP\n")

    result = run_reconcile(cloud, state_path)

    assert result.returncode == 0, result.stderr
    assert cloud.calls == []
    assert VIP in cloud.interfaces[PEER_ENI]["ips"]


def test_master_takes_the_vip_from_the_interface_holding_it(cloud, state_path):
    state_path.write_text("MASTER\n")

    result = run_reconcile(cloud, state_path)

    assert result.returncode == 0, result.stderr
    assert len(cloud.calls) == 1
    call = cloud.calls[0]
    assert call["NetworkInterfaceId"] == NODE_ENI
    assert call["PrivateIpAddress.1"] == VIP
    assert call["AllowReassignment"] == "true"
    assert "DryRun" not in call
    assert cloud.interfaces[NODE_ENI]["ips"] == [NODE_IP, VIP]
    assert cloud.interfaces[PEER_ENI]["ips"] == [PEER_IP]
    assert (state_path.parent / "carried").read_text().strip() == "1"


def test_the_request_is_signed_with_the_credentials_of_the_instance(cloud, state_path):
    state_path.write_text("MASTER\n")

    run_reconcile(cloud, state_path)

    call = cloud.calls[0]
    assert call["_token"] == SESSION_TOKEN
    assert call["_authorization"].startswith(f"AWS4-HMAC-SHA256 Credential={ACCESS_KEY}/")
    assert "/ap-northeast-2/ec2/aws4_request" in call["_authorization"]
    assert "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token" in call["_authorization"]


def test_master_already_carrying_the_vip_asks_the_api_nothing(cloud, state_path):
    state_path.write_text("MASTER\n")
    cloud.interfaces[PEER_ENI]["ips"].remove(VIP)
    cloud.interfaces[NODE_ENI]["ips"].append(VIP)

    result = run_reconcile(cloud, state_path)

    assert result.returncode == 0, result.stderr
    assert cloud.calls == []
    assert (state_path.parent / "carried").read_text().strip() == "1"


def test_an_api_that_fails_is_a_run_that_fails_and_the_next_run_asks_again(cloud, state_path):
    """One attempt per run: the timer of the host is what asks again, so a
    failed run says so with its exit code and the reason, and leaves the
    address where it was."""
    state_path.write_text("MASTER\n")
    cloud.fail_times = 1

    first = run_reconcile(cloud, state_path)
    second = run_reconcile(cloud, state_path)

    assert first.returncode == 1
    assert "InternalError" in first.stderr
    assert second.returncode == 0, second.stderr
    assert len(cloud.calls) == 2
    assert VIP in cloud.interfaces[NODE_ENI]["ips"]


def test_a_node_that_stopped_being_master_does_not_ask_again(cloud, state_path):
    state_path.write_text("MASTER\n")
    cloud.unauthorized = True
    run_reconcile(cloud, state_path)
    assert len(cloud.calls) == 1

    state_path.write_text("BACKUP\n")
    result = run_reconcile(cloud, state_path)

    assert result.returncode == 0, result.stderr
    assert len(cloud.calls) == 1
    assert VIP in cloud.interfaces[PEER_ENI]["ips"]


def test_preflight_passes_on_an_instance_that_may_carry_the_vip(cloud):
    result = run(cloud, "preflight")

    assert result.returncode == 0, result.stderr
    assert cloud.calls[0]["DryRun"] == "true"
    assert VIP in cloud.interfaces[PEER_ENI]["ips"], "a preflight moved the address"


def test_preflight_names_the_permission_the_role_lacks(cloud):
    cloud.unauthorized = True

    result = run(cloud, "preflight")

    assert result.returncode == 1
    assert "ec2:AssignPrivateIpAddresses" in result.stderr
    assert "instance profile" in result.stderr


def test_preflight_names_the_instance_profile_that_is_missing(cloud):
    cloud.has_role = False

    result = run(cloud, "preflight")

    assert result.returncode == 1
    assert "instance profile" in result.stderr
    assert cloud.calls == [], "nothing to sign with, so nothing was asked"


def test_preflight_names_a_vip_outside_the_subnet(cloud):
    result = run(cloud, "preflight", vip="10.0.0.10")

    assert result.returncode == 1
    assert SUBNET in result.stderr
    assert cloud.calls == [], "an address the subnet can not hold is not worth asking the api about"


def test_preflight_names_an_address_aws_keeps_out_of_the_subnet(cloud):
    result = run(cloud, "preflight", vip="172.31.48.2")

    assert result.returncode == 1
    assert "keeps out of every subnet" in result.stderr


def test_preflight_names_the_metadata_that_does_not_answer(cloud):
    cloud.stop()

    result = run(cloud, "preflight")

    assert result.returncode == 1
    assert "instance metadata" in result.stderr


def test_probe_reports_whether_the_vip_is_on_this_interface(cloud):
    assert run(cloud, "probe").stdout.strip() == "0"

    cloud.interfaces[NODE_ENI]["ips"].append(VIP)

    assert run(cloud, "probe").stdout.strip() == "1"


def test_probe_answers_0_rather_than_failing_off_ec2(cloud):
    cloud.stop()

    result = run(cloud, "probe")

    assert result.returncode == 0
    assert result.stdout.strip() == "0"


# The two requests of the aws signature test suite that need nothing but a host
# and a date, with the signatures that suite publishes for them. What they
# establish is that the signer agrees with aws about the shape of the canonical
# request and the key derivation, which the fake api above can not say
SUITE_CREDENTIALS = ("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
SUITE_NOW = datetime.datetime(2015, 8, 30, 12, 36, 0, tzinfo=datetime.timezone.utc)


@pytest.mark.parametrize("method, signature", [
    ("GET", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"),
    ("POST", "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"),
])
def test_the_signer_agrees_with_the_signature_test_suite_of_aws(method, signature):
    module = load_module()
    credentials = module.Credentials(*SUITE_CREDENTIALS)

    headers = module.sign_v4(method, "https://example.amazonaws.com/", {}, b"", "us-east-1", "service",
                             credentials, now=SUITE_NOW)

    assert headers["Authorization"] == (
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request,"
        f" SignedHeaders=host;x-amz-date, Signature={signature}")
