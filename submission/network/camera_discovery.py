#!/usr/bin/env python3
"""
camera_discovery.py — ONVIF Camera Discovery Tool

TASK: Implement a camera discovery script that:
  1. Reads an ONVIF WS-Discovery XML response (like data/onvif_mock_response.xml)
  2. Parses the XML to extract camera information
  3. Outputs a JSON array of discovered cameras
  4. Handles timeouts and malformed XML gracefully

Requirements:
  - Parse the ONVIF ProbeMatch elements
  - Extract: endpoint address (UUID), hardware model, name, location, service URL
  - Output valid JSON to stdout
  - Accept --input flag for XML file path (default: stdin)
  - Accept --timeout flag for discovery timeout in seconds
  - Handle errors gracefully (timeout, parse errors, missing fields)

Example output:
[
  {
    "uuid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "model": "P3265-LVE",
    "name": "AXIS P3265-LVE",
    "location": "LoadingDockA",
    "service_url": "http://10.50.20.101:80/onvif/device_service",
    "ip": "10.50.20.101"
  }
]
"""

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

# XML namespaces used in ONVIF WS-Discovery responses
NAMESPACES = {
    "s":  "http://www.w3.org/2003/05/soap-envelope",
    "d":  "http://schemas.xmlsoap.org/ws/2005/04/discovery",
    "dn": "http://www.onvif.org/ver10/network/wsdl",
}

# ONVIF scope prefixes
SCOPE_HARDWARE = "onvif://www.onvif.org/hardware/"
SCOPE_NAME     = "onvif://www.onvif.org/name/"
SCOPE_LOCATION = "onvif://www.onvif.org/location/"



def parse_args():
    """Parse command line arguments."""
    # TODO: Implement argparse with --input and --timeout flags
    parser = argparse.ArgumentParser(
        description="Parse an ONVIF WS-Discovery response and output camera info as JSON"
    )
    parser.add_argument(
        "--input", "-i",
        metavar="FILE",
        default=None,
        help="Path to ONVIF XML response file (default: stdin)",
    )
    parser.add_argument(
        "--timeout", "-t",
        type=float,
        default=5.0,
        metavar="SECONDS",
        help="Read timeout in seconds when reading from stdin (default: 5.0)",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output",
    )
    return parser.parse_args()

def extract_scope_value(scopes, prefix):
    """Return the value after a known scope prefix, or None if not found."""
    for scope in scopes:
        scope = scope.strip()
        if scope.startswith(prefix):
            return scope[len(prefix):]
    return None


def parse_probe_match(match_elem):
    """
    Parse a single d:ProbeMatch element into a camera dict.
    Returns None and logs a warning if required fields are missing.
    """
    # UUID from endpoint reference
    addr_elem = match_elem.find("d:EndpointReference/d:Address", NAMESPACES)
    if addr_elem is None or not addr_elem.text:
        print("WARNING: ProbeMatch missing EndpointReference/Address — skipping", file=sys.stderr)
        return None

    raw_address = addr_elem.text.strip()
    # Strip the urn:uuid: prefix if present
    uuid = raw_address.replace("urn:uuid:", "")

    # Service URL (XAddrs may contain multiple space-separated URLs — take first)
    xaddrs_elem = match_elem.find("d:XAddrs", NAMESPACES)
    service_url = None
    ip = None
    if xaddrs_elem is not None and xaddrs_elem.text:
        service_url = xaddrs_elem.text.strip().split()[0]
        try:
            ip = urlparse(service_url).hostname
        except Exception:
            ip = None

    # Scopes
    scopes_elem = match_elem.find("d:Scopes", NAMESPACES)
    scopes = scopes_elem.text.split() if (scopes_elem is not None and scopes_elem.text) else []

    model    = extract_scope_value(scopes, SCOPE_HARDWARE)
    name     = extract_scope_value(scopes, SCOPE_NAME)
    location = extract_scope_value(scopes, SCOPE_LOCATION)

    # URL-decode name if encoded (e.g. AXIS%20P3265-LVE -> AXIS P3265-LVE)
    if name:
        from urllib.parse import unquote
        name = unquote(name)

    camera = {
        "uuid":        uuid,
        "model":       model,
        "name":        name,
        "location":    location,
        "service_url": service_url,
        "ip":          ip,
    }

    return camera

def parse_onvif_response(xml_content):
    """Parse ONVIF WS-Discovery XML and return list of camera dicts."""
    # TODO: Implement XML parsing
    # Hint: Use namespaces for SOAP/WS-Discovery/ONVIF elements
    try:
        root = ET.fromstring(xml_content)
    except ET.ParseError as e:
        raise ValueError(f"Malformed XML: {e}") from e

    probe_matches = root.findall(".//d:ProbeMatch", NAMESPACES)

    if not probe_matches:
        print("WARNING: No ProbeMatch elements found in response", file=sys.stderr)
        return []

    cameras = []
    for match in probe_matches:
        camera = parse_probe_match(match)
        if camera is not None:
            cameras.append(camera)

    return cameras

def read_input(args):
    """Read XML from file or stdin, respecting timeout for stdin."""
    if args.input:
        try:
            with open(args.input, "r", encoding="utf-8") as f:
                return f.read()
        except FileNotFoundError:
            print(f"ERROR: File not found: {args.input}", file=sys.stderr)
            sys.exit(1)
        except OSError as e:
            print(f"ERROR: Could not read file: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        # Read from stdin with timeout
        import select
        ready, _, _ = select.select([sys.stdin], [], [], args.timeout)
        if not ready:
            print(f"ERROR: Timed out waiting for input after {args.timeout}s", file=sys.stderr)
            sys.exit(1)
        return sys.stdin.read()
    

def main():
    # TODO: Implement main function
    #   1. Parse arguments
    #   2. Read XML input (from file or stdin)
    #   3. Parse the ONVIF response
    #   4. Output JSON to stdout
    args = parse_args()

    xml_content = read_input(args)

    if not xml_content.strip():
        print("ERROR: Empty input", file=sys.stderr)
        sys.exit(1)

    try:
        cameras = parse_onvif_response(xml_content)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    indent = 2 if args.pretty else None
    print(json.dumps(cameras, indent=indent))



if __name__ == "__main__":
    main()
