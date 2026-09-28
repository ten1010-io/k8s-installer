#!/usr/bin/env python3
"""Asks a ki cp service whether it is answering, and prints what it answered.

Written in python rather than as another shell command because neither of the
two questions has a tool that is certain to be on the node. dig belongs to
bind9-dnsutils, which the nodes do not install and the bind9 image does not
carry, and curl is not a dependency of anything the installer puts down either -
download-bundle.sh asks whether it exists before using it. The interpreter this
runs under is the one ansible itself uses on every managed node, so it is the
one thing that is certainly there.

Nothing here is imported from outside the standard library, for the same reason.

Every subcommand prints a single line and exits 0, including when the answer is
no - one number for dns, and for registry the two numbers it took one connection
to get. The caller writes a metric for every probe it makes and a probe that
failed to answer is a 0 rather than a series that disappears, so an exit code
would be a second channel saying what the line already says.
"""
from __future__ import annotations

import argparse
import http.client
import json
import random
import socket
import ssl
import struct
import sys
import time

# Long enough for a service that is busy, short enough that the whole of a
# collection stays well inside the interval the timer fires on. Per operation,
# not per run: see CATALOG_WALK_SECONDS for what bounds a run
TIMEOUT_SECONDS = 3.0
# What a query asks for. The name being resolved is one this installer wrote
# into the zone itself, so an A record is what the answer holds
DNS_TYPE_A = 1
DNS_CLASS_IN = 1
DNS_HEADER = "!HHHHHH"
DNS_HEADER_SIZE = 12
DNS_RCODE_MASK = 0x000F
# Recursion desired. The server being asked is authoritative for the name, which
# needs no recursion at all, and an authoritative server answers from its zone
# whether or not the bit is set. It is set so that the same probe can be pointed
# at a resolver while it is being worked on, where a query without it comes back
# empty and looks exactly like a failure
DNS_FLAGS_RD = 0x0100
# The largest page a registry accepts. Measured against the registry 2.8 the
# bundle carries: 1000 is answered and 1001 comes back as
# PAGINATION_NUMBER_INVALID, which is a 400 and would read here as a registry
# holding nothing at all
CATALOG_PAGE_SIZE = 1000
# How many pages are followed before this gives up. A hundred of them is a
# hundred thousand repositories, which is far past anything a ki cp registry
# holds, and the bound is what keeps a registry answering with a link to itself
# from being followed for ever
CATALOG_PAGE_LIMIT = 100
# How long the whole walk may take, however few pages that turns out to be. The
# page limit bounds the number of requests and not the time they take: a hundred
# pages of a registry that answers each one just inside TIMEOUT_SECONDS is
# minutes, and the timer fires every sixty seconds. A walk still going when the
# next firing is due has stopped being a measurement of now, so it is abandoned
# and counts as a registry that did not answer
CATALOG_WALK_SECONDS = 20.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    dns_parser = subparsers.add_parser("dns", help="Resolve a name and print 1 when it is answered")
    dns_parser.add_argument("--server", required=True)
    dns_parser.add_argument("--port", type=int, default=53)
    dns_parser.add_argument("--name", required=True)

    # One subcommand for both numbers rather than one each. They are two
    # questions about the same registry and the connection that answers the
    # first is the connection that answers the second, so asking apart is a
    # second interpreter, a second handshake and a second chance for the two
    # numbers to disagree about a registry that went down between them
    registry_parser = subparsers.add_parser(
        "registry", help="Print whether the registry answers and how many repositories it holds")
    add_registry_arguments(registry_parser)

    args = parser.parse_args()

    if args.command == "dns":
        print(1 if resolves(args.server, args.port, args.name) else 0)
        return 0

    up, repositories = ask_registry(args)
    print(f"{up} {repositories}")
    return 0


def add_registry_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--address", required=True)
    parser.add_argument("--port", type=int, required=True)
    # The certificate of a registry carries the name of the ki cp endpoint and
    # not the address this connects to, so the address and the name are given
    # apart: the connection goes to the loopback and the handshake is held to
    # the name. Verified rather than skipped, because an expired or replaced
    # certificate is a registry that has stopped serving every node but this one
    parser.add_argument("--server-name", required=True)
    parser.add_argument("--ca-path", required=True)


def resolves(server: str, port: int, name: str) -> bool:
    """Whether the name server answers a query for this name.

    A connection to the port would say that something is listening, which is not
    the question: bind holds the port open while it is refusing to answer for a
    zone it failed to load. What is asked here is for an answer with a record in
    it
    """
    query_id = random.randint(0, 0xFFFF)

    connection = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    connection.settimeout(TIMEOUT_SECONDS)
    try:
        connection.sendto(build_query(query_id, name), (server, port))
        response, _ = connection.recvfrom(4096)
    except (OSError, UnicodeError):
        return False
    finally:
        connection.close()

    if len(response) < DNS_HEADER_SIZE:
        return False

    response_id, flags, _, answer_count, _, _ = struct.unpack(DNS_HEADER, response[:DNS_HEADER_SIZE])

    return response_id == query_id and (flags & DNS_RCODE_MASK) == 0 and answer_count > 0


def build_query(query_id: int, name: str) -> bytes:
    header = struct.pack(DNS_HEADER, query_id, DNS_FLAGS_RD, 1, 0, 0, 0)

    question = b""
    for label in name.rstrip(".").split("."):
        encoded = label.encode("idna")
        question += struct.pack("!B", len(encoded)) + encoded
    question += b"\x00" + struct.pack("!HH", DNS_TYPE_A, DNS_CLASS_IN)

    return header + question


def ask_registry(args: argparse.Namespace) -> tuple[int, int]:
    """Whether the registry answers, and how many repositories it holds.

    Both of them on one connection. A registry that could not be reached at all
    is 0 and 0; one that answers its version endpoint and then fails part way
    through its catalog is up with a count of 0, because what the count is read
    for is the difference between nodes and a partial count is a difference that
    is not there
    """
    connection = registry_connection(args)
    if connection is None:
        return 0, 0

    try:
        response = registry_get(connection, "/v2/")
        if not response or response[0] != 200:
            return 0, 0

        return 1, registry_repositories(connection)
    finally:
        connection.close()


def registry_repositories(connection: http.client.HTTPSConnection) -> int:
    """How many repositories the registry holds, following its pagination.

    A count that stopped at the first page would be the same number for every
    node once a registry passes it, which is exactly when the comparison between
    the nodes stops working and nothing says so
    """
    total = 0
    path = f"/v2/_catalog?n={CATALOG_PAGE_SIZE}"
    deadline = time.monotonic() + CATALOG_WALK_SECONDS

    for _ in range(CATALOG_PAGE_LIMIT):
        if time.monotonic() >= deadline:
            return 0

        response = registry_get(connection, path)
        if not response or response[0] != 200:
            return 0

        try:
            total += len(json.loads(response[1]).get("repositories") or [])
        except (ValueError, AttributeError):
            return 0

        next_path = next_page_path(response[2])
        if not next_path:
            return total

        path = next_path

    return total


def next_page_path(headers) -> str | None:
    """The path of the next page, out of the Link header the registry sends.

    It arrives as </v2/_catalog?last=<name>&n=<size>>; rel="next" and is absent
    on the last page, which is how the walk above ends
    """
    link = headers.get("Link")
    if not link or 'rel="next"' not in link:
        return None

    try:
        return link[link.index("<") + 1:link.index(">")]
    except ValueError:
        return None


def registry_connection(args: argparse.Namespace):
    """A connection to the registry of this node, or nothing if it cannot be had."""
    raw_socket = None
    try:
        # Inside the try with the rest of it. A certificate authority file that
        # is missing or unreadable is one more way for the registry of this node
        # to be unusable, and every one of those is a 0 rather than a traceback
        context = ssl.create_default_context(cafile=args.ca_path)

        raw_socket = socket.create_connection((args.address, args.port), timeout=TIMEOUT_SECONDS)
        tls_socket = context.wrap_socket(raw_socket, server_hostname=args.server_name)

        # The connection is made here and handed over rather than left to
        # http.client, which would connect to the name it is given. The name is
        # what the handshake has to be held to and the address is where the
        # service is, and on this node those are not the same
        connection = http.client.HTTPSConnection(args.server_name, args.port,
                                                 context=context, timeout=TIMEOUT_SECONDS)
        connection.sock = tls_socket

        return connection
    except (OSError, ssl.SSLError, http.client.HTTPException):
        # Closed here because there is no connection object yet to close it. A
        # handshake that failed leaves the socket open otherwise, and this
        # process goes on to ask a second registry
        if raw_socket is not None:
            raw_socket.close()
        return None


def registry_get(connection: http.client.HTTPSConnection, path: str):
    """One request, on a connection the next request keeps using.

    The body is read to the end whether or not anything wants it, because that
    is what leaves the connection able to carry the page after this one
    """
    # A response the server closed on leaves http.client without a socket, and
    # the request after it would make one of its own - to the name this was
    # given rather than to the loopback it was pointed at, which is the registry
    # of whichever node holds the address. So a connection that has lost its
    # socket ends the walk instead
    if connection.sock is None:
        return None

    try:
        connection.request("GET", path)
        response = connection.getresponse()

        # The headers come back with the rest because the catalog is paginated
        # and the link to the next page is in them
        return response.status, response.read(), response.headers
    except (OSError, ssl.SSLError, http.client.HTTPException):
        return None


if __name__ == "__main__":
    sys.exit(main())
