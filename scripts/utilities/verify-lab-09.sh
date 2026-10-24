#!/usr/bin/env bash
# Verify every Lab 09 control exists and is configured correctly.
# Read-only: this script inspects and changes nothing. Safe to run at any time.
# Exit 0 if every check passes, 1 otherwise.
#
# EXPECTED: PASS=50 FAIL=0 on a build that stores permissions boundaries and
# metadata options. On Floci 1.7.0 expect PASS=48 FAIL=2 - both benign, see
# labs/lab-09-security/README.md Section 5.
#
# Differences from the lab guide's version (each one a bug in the guide on this build):
#   - describe-security-groups queries go through SecurityGroups[0]; the guide's
#     length(IpPermissionsEgress[...]) is applied to the top-level object and errors.
#   - the "unexpanded variable" check matches shell-style ${UPPER_CASE} only, because
#     Lab 01's usms-self-manage-credentials.json legitimately contains ${aws:username}.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-09.env"  2>/dev/null || true

# Defaults so that set -u cannot abort the script before it has told you anything.
: "${USMS_ACCOUNT_ID:=000000000000}"
: "${USMS_VPC_ID:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_DB_SG:=none}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ALB_SG:=none}"
: "${USMS_BASTION_SG:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_RT:=none}"
: "${USMS_DEV_USER:=usms-dev-01}"
: "${USMS_INSTANCE_PROFILE:=usms-ec2-app-profile}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ECS_TASK_ROLE:=usms-ecs-task-role}"
: "${USMS_WEB_INSTANCE:=none}"
: "${USMS_DB_INSTANCE:=none}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# One policy document, by policy name, at its DEFAULT version.
polarn() {
  aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='$1'].Arn | [0]" --output text 2>/dev/null
}
poldoc() {
  arn=$(polarn "$1")
  [ -n "$arn" ] && [ "$arn" != "None" ] || return 1
  ver=$(aws iam get-policy --policy-arn "$arn" \
          --query 'Policy.DefaultVersionId' --output text 2>/dev/null)
  aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" \
    --query 'PolicyVersion.Document' --output json 2>/dev/null
}
attachcount() {
  aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='$1'].AttachmentCount | [0]" --output text 2>/dev/null
}
# Actions in one policy's statements of one Effect, one per line.
actions() {
  poldoc "$1" | python3 -c "
import json,sys
d=json.load(sys.stdin); sts=d['Statement'] if isinstance(d['Statement'],list) else [d['Statement']]
for s in sts:
    if s['Effect']=='$2':
        a=s['Action']; print('\n'.join(a if isinstance(a,list) else [a]))"
}
# Egress rules on a group that are the AWS default allow-all shape.
allowall() {
  aws ec2 describe-security-groups --group-ids "$1" \
    --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`-1`])' --output text 2>/dev/null
}
sgq() {
  aws ec2 describe-security-groups --group-ids "$1" --query "$2" --output text 2>/dev/null
}

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Labs 01 to 06 dependencies still present =="
check "usms-vpc exists" "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "$USMS_ECS_TASK_ROLE exists" "aws iam get-role --role-name $USMS_ECS_TASK_ROLE"
check "$USMS_INSTANCE_PROFILE exists" \
  "aws iam get-instance-profile --instance-profile-name $USMS_INSTANCE_PROFILE"
check "$USMS_ENROLMENT_SERVICE is ACTIVE" \
  "test \"\$(aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'services[0].status' --output text)\" = ACTIVE"
check "USMSStudentDataReadWrite is still on at least TWO roles (Lab 10 needs them)" \
  "test \"\$(aws iam list-entities-for-policy --policy-arn arn:aws:iam::$USMS_ACCOUNT_ID:policy/USMSStudentDataReadWrite --query 'length(PolicyRoles)' --output text)\" -ge 2"

echo "== Lab 09 identity: the read-only split =="
check "USMSStudentDataReadOnly exists" "polarn USMSStudentDataReadOnly | grep -q '^arn:'"
check "it ALLOWS s3:GetObject" "actions USMSStudentDataReadOnly Allow | grep -qx 's3:GetObject'"
check "it does NOT allow s3:PutObject" "! actions USMSStudentDataReadOnly Allow | grep -qx 's3:PutObject'"
check "it explicitly DENIES s3:PutObject" "actions USMSStudentDataReadOnly Deny | grep -qx 's3:PutObject'"
check "usms-transcripts-reader-role exists" \
  "aws iam get-role --role-name usms-transcripts-reader-role"
check "it carries USMSStudentDataReadOnly" \
  "aws iam list-attached-role-policies --role-name usms-transcripts-reader-role --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSStudentDataReadOnly"

echo "== Lab 09 identity: the confused-deputy fix =="
check "$USMS_ECS_TASK_ROLE trust policy has a Condition" \
  "test \"\$(aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'length(Role.AssumeRolePolicyDocument.Statement[0].Condition)' --output text)\" -ge 1"
check "its principal is STILL ecs-tasks.amazonaws.com" \
  "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q 'ecs-tasks.amazonaws.com'"
check "the condition pins aws:SourceAccount to this account" \
  "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals.\"aws:SourceAccount\"' --output text | grep -qx '$USMS_ACCOUNT_ID'"

echo "== Lab 09 identity: PassRole and the boundary =="
check "USMSDeployBase exists" "polarn USMSDeployBase | grep -q '^arn:'"
check "its iam:PassRole names role ARNs, not Resource \"*\"" \
  "poldoc USMSDeployBase | python3 -c \"import json,sys;d=json.load(sys.stdin);L=lambda x:x if isinstance(x,list) else [x];bad=[s for s in d['Statement'] if s['Effect']=='Allow' and 'iam:PassRole' in L(s['Action']) and '*' in L(s['Resource'])];sys.exit(1 if bad else 0)\""
check "its iam:PassRole carries an iam:PassedToService condition" \
  "poldoc USMSDeployBase | grep -q 'iam:PassedToService'"
check "USMSPermissionsBoundary exists" "polarn USMSPermissionsBoundary | grep -q '^arn:'"
check "the boundary is attached to NOTHING as an ordinary policy" \
  "test \"\$(attachcount USMSPermissionsBoundary)\" = 0"
check "usms-deploy-role exists" "aws iam get-role --role-name usms-deploy-role"
check "usms-deploy-role HAS a permissions boundary" \
  "aws iam get-role --role-name usms-deploy-role --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text | grep -q 'USMSPermissionsBoundary'"
check "usms-deploy-role trusts a USER, not a service" \
  "aws iam get-role --role-name usms-deploy-role --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.AWS' --output text | grep -q ':user/'"

echo "== Lab 09 credentials and metadata =="
check "$USMS_DEV_USER has EXACTLY ONE access key" \
  "test \"\$(aws iam list-access-keys --user-name $USMS_DEV_USER --query 'length(AccessKeyMetadata)' --output text)\" = 1"
check "that key is Active" \
  "test \"\$(aws iam list-access-keys --user-name $USMS_DEV_USER --query 'AccessKeyMetadata[0].Status' --output text)\" = Active"
check "usms-web-01 requires IMDSv2" \
  "test \"\$(aws ec2 describe-instances --instance-ids $USMS_WEB_INSTANCE --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)\" = required"

echo "== Lab 09 network: ingress unchanged =="
check "usms-alb-sg still admits tcp/80 from 0.0.0.0/0" \
  "sgq $USMS_ALB_SG 'SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[].CidrIp' | grep -q '0.0.0.0/0'"
check "usms-enrolment-sg still admits tcp/80 from usms-alb-sg" \
  "sgq $USMS_ENROLMENT_SG 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' | grep -qw $USMS_ALB_SG"
check "usms-db-sg still admits tcp/5432 from usms-app-sg" \
  "sgq $USMS_DB_SG 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' | grep -qw $USMS_APP_SG"

echo "== Lab 09 network: egress written =="
check "usms-alb-sg has NO allow-all egress rule" "test \"\$(allowall $USMS_ALB_SG)\" = 0"
check "usms-alb-sg egress destination is a GROUP, not a CIDR" \
  "sgq $USMS_ALB_SG 'SecurityGroups[0].IpPermissionsEgress[].UserIdGroupPairs[].GroupId' | grep -qw $USMS_ENROLMENT_SG"
check "usms-enrolment-sg has NO allow-all egress rule" "test \"\$(allowall $USMS_ENROLMENT_SG)\" = 0"
check "usms-enrolment-sg egress is tcp/443 only" \
  "test \"\$(sgq $USMS_ENROLMENT_SG 'length(SecurityGroups[0].IpPermissionsEgress[?FromPort!=\`443\`])')\" = 0"
check "usms-db-sg has NO allow-all egress rule" "test \"\$(allowall $USMS_DB_SG)\" = 0"
check "usms-db-sg egress is tcp/443 only" \
  "test \"\$(sgq $USMS_DB_SG 'length(SecurityGroups[0].IpPermissionsEgress[?FromPort!=\`443\`])')\" = 0"

echo "== Lab 09 network: the SSH cutover =="
check "usms-bastion-sg exists" \
  "aws ec2 describe-security-groups --filters Name=group-name,Values=usms-bastion-sg Name=vpc-id,Values=$USMS_VPC_ID --query 'SecurityGroups[0].GroupId' --output text | grep -q '^sg-'"
check "usms-app-sg admits tcp/22 from a GROUP" \
  "sgq $USMS_APP_SG 'SecurityGroups[0].IpPermissions[?FromPort==\`22\`].UserIdGroupPairs[].GroupId' | grep -q '^sg-'"
check "usms-app-sg has NO CIDR source on tcp/22" \
  "test \"\$(sgq $USMS_APP_SG 'length(SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[])')\" = 0"

echo "== The negatives that must stay true =="
check "usms-db-01 has NO public address" \
  "test \"\$(aws ec2 describe-instances --instance-ids $USMS_DB_INSTANCE --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)\" = None"
check "the private subnet does NOT auto-assign public addresses" \
  "test \"\$(aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A --query 'Subnets[0].MapPublicIpOnLaunch' --output text)\" = False"
check "the private route table has NO internet gateway route" \
  "! aws ec2 describe-route-tables --route-table-ids $USMS_PRIVATE_RT --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q 'igw-'"

echo "== Files, documents and Git hygiene =="
check "configs/lab-09.env exists" "test -f configs/lab-09.env"
check "configs/lab-09.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-09.env"
check "every policies/ document is valid JSON" \
  "for f in policies/*.json; do python3 -m json.tool \"\$f\" >/dev/null || exit 1; done"
check "no policies/ document contains an unexpanded shell variable" \
  "! grep -lE '\\\$\\{?[A-Z_]{2,}' policies/*.json"
check "the three audit scripts exist and are executable" \
  "test -x scripts/utilities/usms-iam-audit.sh && test -x scripts/utilities/usms-sg-audit.sh && test -x scripts/utilities/usms-reachability-matrix.sh"
check "no secret is tracked by git" "! git ls-files | grep -q '^outputs/[^.]'"

echo; echo "PASS=$PASS  FAIL=$FAIL"

if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

A failure under "== Environment ==" is the real problem, and most failures below it are
a consequence. Fix that block first:
    ./scripts/utilities/floci-storage-check.sh

A failure under "== Labs 01 to 06 dependencies ==" means an earlier lab's resource is
gone. Run verify-lab-02.sh, verify-lab-03.sh, verify-lab-04.sh, verify-lab-05.sh and
verify-lab-06.sh before re-reading anything here.

Known benign failures on Floci 1.7.0 (record them, do not fight them):
    usms-deploy-role HAS a permissions boundary   - boundary accepted, never stored
    usms-web-01 requires IMDSv2                    - ModifyInstanceMetadataOptions unsupported

A failure under "== The negatives that must stay true ==" is the most serious kind in
this script: something that was unreachable has become reachable. Stop and find out
what changed before doing anything else.
REMEDY
fi

[ "$FAIL" -eq 0 ]
