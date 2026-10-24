#!/usr/bin/env bash
# Lab 09 Exercise 5 - draft the RESOURCE policy for the transcripts bucket.
#
# Reads only IAM (policy documents and who carries them). Writes:
#   outputs/lab-09-bucket-policy-draft.json   the draft bucket policy (applied by the S3 lab, not here)
#   outputs/lab-09-lab10-readiness.txt         a labelled summary Lab 10 can read without this lab
# Applies NOTHING. Works whether or not the bucket exists. Never reads or mentions an access key.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
ACCOUNT="${USMS_ACCOUNT_ID:-000000000000}"

# --- 1. derive the bucket name FROM LAB 01's POLICY DOCUMENT, never by typing it -----------
RW_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)
RW_VER=$(aws iam get-policy --policy-arn "$RW_ARN" --query 'Policy.DefaultVersionId' --output text)
BUCKET_ARN=$(aws iam get-policy-version --policy-arn "$RW_ARN" --version-id "$RW_VER" \
  --query 'PolicyVersion.Document' --output json \
  | python3 -c 'import json,sys
d=json.load(sys.stdin); sts=d["Statement"] if isinstance(d["Statement"],list) else [d["Statement"]]
res=[r for s in sts for r in (s["Resource"] if isinstance(s["Resource"],list) else [s["Resource"]])]
print(next(r for r in res if r.startswith("arn:aws:s3:::") and "/" not in r))')
# Shell parameter expansion, not another python call: "${VAR#prefix}" strips the shortest
# leading match of the literal ARN prefix, leaving exactly the bucket name. It is a pure string
# operation, so it cannot fail on a missing bucket and needs no API call.
BUCKET="${BUCKET_ARN#arn:aws:s3:::}"
[ -n "$BUCKET" ] && [ "$BUCKET" != "$BUCKET_ARN" ] || { echo "could not derive the bucket name" >&2; exit 2; }
echo "bucket (from USMSStudentDataReadWrite's Resource): $BUCKET"

# --- 2. every customer policy whose DOCUMENT names the bucket, and who carries it ----------
python3 - "$BUCKET" "$ACCOUNT" << 'PY'
import json, subprocess, sys
bucket, account = sys.argv[1], sys.argv[2]
b_arn, o_arn = f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"

def aws(*a):
    r = subprocess.run(["aws", *a, "--output", "json"], capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None
L = lambda x: [] if x is None else (x if isinstance(x, list) else [x])

def in_bucket(resource):
    """The part of a Resource that falls inside this bucket, kept EXACTLY as written, so a role
    limited to reports/* stays limited to reports/* (widening it would grant more than it has)."""
    if resource == b_arn or resource.startswith(b_arn + "/"):
        return [resource]
    if resource in ("*", "arn:aws:s3:::*"):
        return [b_arn, o_arn]
    return []

policies, grants = [], {}            # grants[role_arn][(resource, condition_json)] = set(actions)
for p in (aws("iam", "list-policies", "--scope", "Local") or {}).get("Policies", []):
    ver = (aws("iam", "get-policy", "--policy-arn", p["Arn"]) or {}).get("Policy", {}).get("DefaultVersionId")
    doc = (aws("iam", "get-policy-version", "--policy-arn", p["Arn"], "--version-id", ver) or {}).get("PolicyVersion", {}).get("Document") if ver else None
    if not doc or b_arn not in json.dumps(doc):
        continue
    roles = [r["RoleName"] for r in (aws("iam", "list-entities-for-policy", "--policy-arn", p["Arn"]) or {}).get("PolicyRoles", [])]
    granted = {}                        # (resource, condition) -> actions, from Allow statements only
    for s in L(doc.get("Statement")):
        if s.get("Effect") != "Allow":
            continue                    # a Deny grants nothing
        s3 = [a for a in L(s.get("Action")) if a.lower().startswith("s3:") or a == "*"]
        if not s3:
            continue
        cond = json.dumps(s.get("Condition"), sort_keys=True) if s.get("Condition") else ""
        for r in L(s.get("Resource")):
            for br in in_bucket(r):
                granted.setdefault((br, cond), set()).update(s3)
    policies.append({"policy": p["PolicyName"], "roles": roles,
                     "grants": [{"resource": k[0], "condition": json.loads(k[1]) if k[1] else None,
                                 "actions": sorted(v)} for k, v in granted.items()]})
    for rn in roles:
        g = grants.setdefault(f"arn:aws:iam::{account}:role/{rn}", {})
        for k, v in granted.items():
            g.setdefault(k, set()).update(v)

grants = {k: v for k, v in grants.items() if v}
root = f"arn:aws:iam::{account}:root"

statements = []
for role, g in sorted(grants.items()):
    name = role.rsplit("/", 1)[-1].replace("-", " ").title().replace(" ", "")
    for n, ((res, cond), acts) in enumerate(sorted(g.items()), 1):
        st = {"Sid": f"Allow{name}{n}", "Effect": "Allow", "Principal": {"AWS": role},
              "Action": sorted(acts), "Resource": res}
        if cond:
            st["Condition"] = json.loads(cond)       # keep e.g. an s3:prefix limit exactly
        statements.append(st)
statements.append({"Sid": "DenyAnyRequestNotOverTLS", "Effect": "Deny", "Principal": "*",
                   "Action": "s3:*", "Resource": [b_arn, o_arn],
                   "Condition": {"Bool": {"aws:SecureTransport": "false"}}})
statements.append({"Sid": "DenyEveryoneExceptTheseRolesAndTheAccountRoot", "Effect": "Deny",
                   "NotPrincipal": {"AWS": sorted(grants) + [root]},
                   "Action": "s3:*", "Resource": [b_arn, o_arn]})

draft = {"Version": "2012-10-17", "Id": f"{bucket}-draft-from-lab-09", "Statement": statements}
json.dump(draft, open("outputs/lab-09-bucket-policy-draft.json", "w"), indent=2)

# --- 3. mechanical checks ------------------------------------------------------------------
problems = []
for s in statements:
    pr = s.get("Principal", s.get("NotPrincipal"))
    if pr == "*" and s["Sid"] != "DenyAnyRequestNotOverTLS":
        problems.append(f"{s['Sid']}: Principal \"*\" outside the TLS deny")
    if isinstance(pr, dict) and not all(a.startswith("arn:aws:iam::") for a in L(pr.get("AWS"))):
        problems.append(f"{s['Sid']}: a principal is not an ARN")
text = json.dumps(draft)
if f'"{b_arn}"' not in text: problems.append("bucket ARN without /* missing")
if f'"{o_arn}"' not in text: problems.append("bucket ARN with /* missing")
print("mechanical checks:", "PASS" if not problems else "FAIL " + "; ".join(problems))

# --- 4. readiness file ----------------------------------------------------------------------
with open("outputs/lab-10-readiness.tmp", "w") as f:
    f.write(f"bucket name (read from USMSStudentDataReadWrite) : {bucket}\n")
    f.write(f"policies naming the bucket                      : {', '.join(p['policy'] for p in policies)}\n")
    for p in policies:
        f.write(f"  {p['policy']:<30} roles: {', '.join(p['roles']) or '(attached to nothing)'}\n")
    f.write(f"role ARNs granted s3 actions on the bucket       : {', '.join(sorted(grants))}\n")
    f.write(f"principal count in the draft (roles + root)      : {len(grants) + 1}\n")
    f.write("what changes when Lab 10 runs create-bucket      : nothing in IAM changes, but every role above "
            "stops holding permissions on a non-existent ARN and can immediately read (and the read-write ones "
            "write) real transcripts - until the S3 lab applies this draft, the bucket has no resource policy, "
            "so only these identity policies (and the account root) decide access.\n")
print(f"{len(policies)} policies name the bucket; {len(grants)} roles granted s3 actions; draft has {len(statements)} statements")
PY
mv outputs/lab-10-readiness.tmp outputs/lab-09-lab10-readiness.txt
python3 -m json.tool outputs/lab-09-bucket-policy-draft.json > /dev/null && echo "draft is valid JSON"
