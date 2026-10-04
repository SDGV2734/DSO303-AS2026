# Lab 03 Notes

## Step 11 — IAM permission chain

An IAM policy can grant access to a resource that does not exist yet because it is a statement about ARNs, not a reference to existing objects. When Lab 4 creates the `usms-student-data` bucket, the policy attached through `usms-ec2-app-profile` will stop being hypothetical, and `usms-web-01` will be able to write transcripts without storing an AWS access key on the instance.

## Review questions

### 1. What Step 8 reused, and how each dependency could fail

Step 8 combined five inputs. The subnet came from Lab 2 and determined the VPC,
Availability Zone, address range, route-table association, and whether a public
address was assigned. A nonexistent subnet ID would fail `run-instances`
immediately; a valid but wrong subnet would launch successfully and silently put
the server in the wrong network. The security group also came from Lab 2. A
missing group ID would fail immediately, while a valid but wrong group would be
a silent configuration error that might expose the server or block port 80. The
instance profile came from Lab 1. Naming a nonexistent profile would fail the
launch, but attaching the wrong valid profile would launch successfully and fail
later when the application attempted an AWS API call. The key pair came from Lab
3. A nonexistent key name would fail immediately; the wrong valid key would be
noticed only when nobody could authenticate with the expected private key. The
user-data script also came from Lab 3. Omitting it or supplying syntactically bad
shell would normally not make `run-instances` fail: the VM would launch, but its
bootstrap would be absent or fail inside cloud-init. This is why reading each
association and payload back is stronger evidence than a successful launch call.

### 2. A policy for a bucket that does not yet exist

`USMSStudentDataReadWrite` is valid because an IAM policy describes allowed and
denied actions against ARN strings; policy creation does not require the named
resource to exist. Today the instance-to-profile-to-role-to-policy chain is
complete, but S3 operations against `arn:aws:s3:::usms-student-data` fail because
there is no bucket on which the permission can act. At the moment the later lab
creates exactly that bucket ARN, no IAM object or instance credential needs to
change: the existing role permission becomes applicable, and temporary
credentials delivered through the instance profile authorize the allowed bucket
and object operations. The explicit `s3:DeleteBucket` deny continues to win. No
long-lived access key needs to be written to the instance.

### 3. User data is not a restart-time deployment mechanism

Stock cloud-init runs ordinary user data once during the instance's first boot.
Stopping, starting, or rebooting the same instance therefore does not redeploy
the application. One alternative is an external deployment/configuration system
such as a CI/CD pipeline, AWS Systems Manager, Ansible, or CodeDeploy that is
invoked for each release and records its state. A second is to build an immutable
AMI containing the tested application and replace instances through a launch
template and Auto Scaling rolling deployment. If work truly must run on every OS
boot, an idempotent `systemd` unit can do so, but it should not be confused with
default one-time cloud-init behavior.

### 4. Auto-assigned public IPv4 versus an Elastic IP

An auto-assigned public IPv4 is temporarily assigned by AWS to the instance's
network interface; the account does not reserve that particular address. It is
released when a real EC2 instance stops and a later start normally receives a
different address. An Elastic IP is an account-owned regional allocation that
remains allocated until explicitly released. It can stay associated across
stop/start and can be moved between instances. Public IPv4 and Elastic IP
pricing depends on current AWS rules, but an allocated address has its own cost
lifecycle and leaving one unused can still cost money. During failover, an
operator can disassociate the Elastic IP from a failed web instance and associate
the same allocation with a healthy replacement, preserving the client-facing
address—something impossible with the failed instance's released auto-assigned
address. Floci modelled the association but used a non-routable plausible value.

### 5. EBS Availability Zones and snapshots

An EBS volume is an Availability Zone resource backed by storage infrastructure
inside one AZ, so EC2 cannot attach it directly to an instance in another AZ. An
EBS snapshot is stored as a regional service object and can be used to create a
new volume in a chosen AZ in the same region. Therefore a design that must survive
an AZ loss cannot rely on moving the original volume during the incident. It
needs current snapshots or application-level replication, then creates a new
volume in the surviving AZ and attaches that new resource to a replacement
instance. Snapshot recency determines the possible recovery-point loss, while
automation and volume creation time affect the recovery time.

### 6. Is Step 14's configuration proof adequate?

The six checks are adequate to prove the AWS-side path is configured: the
instance is running, the subnet has an internet-gateway route, the gateway is
attached, the security group admits port 80, a public address exists, and the
NACL permits the path. They are not equivalent to an end-to-end request. They
cannot detect guest/application faults such as nginx not being installed,
cloud-init failing, a service listening only on localhost or the wrong port, a
host firewall rejecting traffic, or the application returning errors. The
specific missing class is anything inside the guest OS and process layer. On
real AWS I would retain these configuration checks and add a TCP/HTTP health
check from outside the VPC . 

### 7. Web tier versus data tier: instance, subnet, and VPC properties

Both `usms-web-01` and `usms-db-01` use the same base AMI, `t3.micro` instance
type, VPC, region, and Availability Zone A. Their differences are:

- **Instance properties:** different instance IDs, names and tier tags; the web
  instance has `usms-app-sg`, `usms-ec2-app-profile`, web bootstrap user data, an
  Elastic IP association, and the separate data volume. The database instance
  has `usms-db-sg`, no instance profile, no public address and no web user data.
- **Subnet properties:** web is in `usms-public-subnet-a` (`10.0.1.0/24`) with
  public-IP-on-launch enabled and an association to the public route table;
  database is in `usms-private-subnet-a` (`10.0.3.0/24`) with public assignment
  disabled and an association to the private route table and private NACL.
- **VPC/network properties around them:** the public route table sends
  `0.0.0.0/0` to the internet gateway, whereas the private route table sends
  outbound traffic through the NAT gateway and has no IGW route. Both inherit
  the same VPC DNS settings and local route. Security groups themselves belong
  to the VPC, but selecting which group is attached is part of each instance's
  launch configuration; their rules create the intended web-to-database trust
  relationship.
