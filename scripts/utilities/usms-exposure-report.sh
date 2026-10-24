#!/usr/bin/env bash
# USMS exposure report (Lab 09 Exercise 3).
#
# One line per network interface in usms-vpc, with a verdict COMPUTED from three facts
# and nothing else - never from names, tags or descriptions (those are only used to LABEL a row):
#   1. does the interface's subnet route to an internet gateway?   (its explicit route table,
#      or the VPC's main route table when the subnet has no explicit association)
#   2. does the interface have a public address?                   (the ENI association, or the
#      attached instance's PublicIpAddress, which is where Floci reports it)
#   3. does any of its security groups admit something from 0.0.0.0/0 or ::/0?
#
# Verdicts:
#   EXPOSED      igw route + public address + an ingress rule open to the internet
#   ADDRESSABLE  igw route + public address, but NO ingress rule admits the internet. The
#                internet has an address to send to and a route back, but nothing is let in.
#                Not EXPOSED (nothing listens for the internet), not ISOLATED either: one rule
#                added to its group would make it EXPOSED, so it is listed separately.
#   INTERNAL     igw route on the subnet but no public address (nothing to send to)
#   ISOLATED     no igw route on the subnet's route table
#   UNKNOWN      a security group could not be read - never guessed as safe
#
# Usage: usms-exposure-report.sh   (no arguments; runs from any directory)
#
# set -uo pipefail WITHOUT -e: this is a report. One failing describe call (a group deleted
# mid-run, an interface of a terminated instance) must become one UNKNOWN line, not a silently
# truncated report. Every aws call below is checked explicitly instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

VPC="${USMS_VPC_ID:-}"
[ -n "$VPC" ] || { echo "USMS_VPC_ID not set - configs/lab-02.env missing?" >&2; exit 2; }

OUT_JSON="$REPO_ROOT/outputs/lab-09-exposure.json"

python3 - "$VPC" "$OUT_JSON" << 'PY'
import json, subprocess, sys

vpc, out_json = sys.argv[1], sys.argv[2]

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return json.loads(r.stdout)

enis   = (aws("ec2", "describe-network-interfaces", "--filters", f"Name=vpc-id,Values={vpc}") or {}).get("NetworkInterfaces", [])
rts    = (aws("ec2", "describe-route-tables", "--filters", f"Name=vpc-id,Values={vpc}") or {}).get("RouteTables", [])
groups = {g["GroupId"]: g for g in (aws("ec2", "describe-security-groups", "--filters", f"Name=vpc-id,Values={vpc}") or {}).get("SecurityGroups", [])}
insts  = {}
for r in (aws("ec2", "describe-instances", "--filters", f"Name=vpc-id,Values={vpc}") or {}).get("Reservations", []):
    for i in r.get("Instances", []):
        insts[i["InstanceId"]] = i

# subnet -> route table: explicit association first, the VPC's main table otherwise
main_rt, by_subnet = None, {}
for rt in rts:
    for a in rt.get("Associations", []):
        if a.get("Main"):
            main_rt = rt
        if a.get("SubnetId"):
            by_subnet[a["SubnetId"]] = rt

def has_igw(rt):
    return bool(rt) and any((r.get("GatewayId") or "").startswith("igw-") for r in rt.get("Routes", []))

def group(gid):
    """Cached lookup, falling back to a direct call for a group not in the VPC listing."""
    if gid not in groups:
        g = (aws("ec2", "describe-security-groups", "--group-ids", gid) or {}).get("SecurityGroups", [])
        groups[gid] = g[0] if g else None
    return groups[gid]

def open_ports(g):
    ports = []
    for p in g.get("IpPermissions", []):
        cidrs = [r.get("CidrIp") for r in p.get("IpRanges", [])] + [r.get("CidrIpv6") for r in p.get("Ipv6Ranges", [])]
        if any(c in ("0.0.0.0/0", "::/0") for c in cidrs):
            lo = p.get("FromPort")
            ports.append("all" if lo is None else str(lo))
    return ports

rows = []
for e in enis:
    att  = e.get("Attachment") or {}
    inst = insts.get(att.get("InstanceId") or "")
    tags = {t["Key"]: t["Value"] for t in (inst or {}).get("Tags", [])}
    # LABEL only - the verdict below never reads these
    label = tags.get("Name") or e.get("Description") or e.get("InterfaceType") or e["NetworkInterfaceId"]
    state = (inst or {}).get("State", {}).get("Name") if inst else ("no-instance" if att.get("InstanceId") else "-")
    stale = state in ("terminated", "no-instance")

    public = (e.get("Association") or {}).get("PublicIp") or (inst or {}).get("PublicIpAddress")
    rt     = by_subnet.get(e.get("SubnetId")) or main_rt
    igw    = has_igw(rt)

    unknown, ports = [], []
    for gref in e.get("Groups", []):
        g = group(gref["GroupId"])
        if g is None:
            unknown.append(gref["GroupId"])
        else:
            ports += open_ports(g)

    if not igw:
        verdict, why = "ISOLATED", "no igw route on subnet"
    elif unknown:
        verdict, why = "UNKNOWN", "cannot read group(s) " + ",".join(unknown)
    elif not public:
        verdict, why = "INTERNAL", "igw route, but no public address"
    elif ports:
        verdict, why = "EXPOSED", "igw route + sg allows " + ",".join(sorted(set(ports))) + " from 0.0.0.0/0"
    else:
        verdict, why = "ADDRESSABLE", "igw route + public address, but no ingress rule admits the internet"
    if stale:
        why += f"  [interface of a {state} instance - should not exist]"
    elif state not in ("-", "running"):
        why += f"  [instance {state}]"

    rows.append({"name": label, "interface": e["NetworkInterfaceId"], "instance": att.get("InstanceId"),
                 "instanceState": state, "subnet": e.get("SubnetId"),
                 "routeTable": (rt or {}).get("RouteTableId"),
                 "routeTableSource": "explicit" if e.get("SubnetId") in by_subnet else "main",
                 "private": e.get("PrivateIpAddress"), "public": public, "igwRoute": igw,
                 "internetOpenPorts": sorted(set(ports)), "verdict": verdict, "reason": why})

order = {"EXPOSED": 0, "UNKNOWN": 1, "ADDRESSABLE": 2, "INTERNAL": 3, "ISOLATED": 4}
rows.sort(key=lambda r: (order[r["verdict"]], r["name"]))
for r in rows:
    print(f"{r['name']:<18} {r['private'] or '-':<14} {r['public'] or '-':<14} {r['verdict']:<12} {r['reason']}")
print()
summary = {v: sum(1 for r in rows if r["verdict"] == v) for v in order}
print("  ".join(f"{k}={v}" for k, v in summary.items()) + f"  interfaces={len(rows)}")

json.dump({"vpc": vpc, "summary": summary, "interfaces": rows}, open(out_json, "w"), indent=2)
PY
