# Lab 02 – Review Questions

## Virtual Private Cloud and Networking

---

## Question 1

### A colleague creates a subnet, names it `public-subnet`, tags it `Tier=public`, and enables auto-assign public IPv4. Instances still cannot reach the internet. What is missing?

The missing component is an effective route from the subnet to an Internet Gateway. For IPv4 internet connectivity, the subnet normally needs a route such as `0.0.0.0/0` whose target is an Internet Gateway attached to the VPC.

The subnet name does not affect routing because AWS treats the name only as a tag used for identification. Similarly, the `Tier=public` tag is metadata and does not change network behaviour. Enabling automatic public IPv4 assignment gives instances a public address, but an address by itself does not provide a network path.

Therefore, the subnet becomes internet-routable only when its effective route table directs internet traffic to an attached Internet Gateway. In Lab 02, this was demonstrated by comparing `usms-public-subnet-a` with `usms-private-subnet-a`. The important difference was the route table, not the subnet name or tags.

---

## Question 2

### Explain the difference between stateful security groups and stateless Network ACLs using a USMS request path.

Security groups are stateful, while Network ACLs are stateless. This changes the number of rules required for a connection.

For example, a student's browser may connect to the USMS application server using TCP port 443. The application security group allows inbound HTTPS from the client. Because the security group is stateful, the response from the web server is automatically allowed as return traffic and does not require a separate outbound response rule.

The web server may then need information from the database and initiate a PostgreSQL connection on TCP port 5432. The database security group permits TCP 5432 from `usms-app-sg`. Once the database accepts this connection, its return traffic is also automatically permitted because the security group remembers the connection state.

A Network ACL behaves differently. It evaluates inbound and outbound packets independently. If a request is permitted inbound but the appropriate outbound return traffic is not allowed, the reply is dropped. This is why custom NACLs normally require rules for ephemeral ports such as TCP 1024–65535.

For most new application access-control requirements, I would use security groups first because they are stateful, operate close to the instance or network interface and can reference other security groups directly. I would use a NACL mainly as an additional subnet-wide control or backstop.

---

## Question 3

### Why does `usms-db-sg` allow PostgreSQL from `usms-app-sg` instead of `10.0.1.0/24`?

Referencing `usms-app-sg` makes the database access rule depend on the identity of the application tier instead of its current IP address range.

One architecture change that would break a CIDR-based `10.0.1.0/24` rule is moving an application server from `usms-public-subnet-a` to `usms-public-subnet-b`, which uses `10.0.2.0/24`. The new server would no longer match the original CIDR rule even though it still performs the same application role.

A second example is scaling the web tier across multiple subnets or Availability Zones. New application instances could receive addresses outside `10.0.1.0/24`, forcing the database rule to be updated every time the network placement changed.

With the group-referenced design, any legitimate application instance associated with `usms-app-sg` can connect to PostgreSQL regardless of which approved subnet it is placed in. This makes the rule more closely represent the architecture and reduces dependence on fixed addresses.

---

## Question 4

### Why is the NAT Gateway located in `usms-public-subnet-a`, and what happens if AZ a fails?

The NAT Gateway must be able to reach the Internet Gateway because its purpose is to provide outbound internet connectivity for resources that do not have a direct internet route.

For this reason, `usms-nat` is placed in `usms-public-subnet-a`, whose route table contains a default route to `usms-igw`. The private route table does not point directly to the Internet Gateway. Instead, it sends its `0.0.0.0/0` traffic to the NAT Gateway.

This creates the required asymmetric behaviour: a private instance can initiate a connection to the internet, for example to download a security update, but an internet host cannot use the NAT Gateway to initiate a new connection directly to that private instance.

However, the NAT Gateway used in this lab is located only in Availability Zone a. If AZ a becomes unavailable, a private subnet in AZ b that relies on this NAT Gateway would lose its outbound internet path even if its own instances and subnet remained available.

This means that simply distributing subnets across two Availability Zones does not automatically make every network dependency highly available. The outbound availability boundary still includes the AZ containing the NAT Gateway. A more resilient production design would normally provide an appropriate NAT path in each Availability Zone and route each private subnet through the NAT Gateway in its own AZ.

---

## Question 5

### How does the S3 Gateway Endpoint change the path to `usms-student-data`?

With the S3 Gateway Endpoint, a request from an instance in the private tier is matched by the S3 service route associated with the private route table. The request is therefore directed through `usms-s3-endpoint` to Amazon S3 rather than following the normal default route through the NAT Gateway.

The intended path with the endpoint is:

Private instance → private route table → S3 Gateway Endpoint → Amazon S3.

Without the endpoint, the private instance would use the private route table's default route. The traffic would go from the private subnet to the NAT Gateway, from the NAT Gateway through the public internet-facing path, and then reach S3.

The endpoint therefore avoids using the NAT Gateway for S3 traffic. Under the design explained in this lab, the path without the endpoint uses the internet-facing/NAT path, while the endpoint keeps the service traffic on the AWS service path.

This has both cost and security benefits. NAT Gateways have hourly and data-processing charges, so sending large amounts of S3 traffic through a NAT Gateway creates unnecessary cost. Using the endpoint also reduces exposure to the public internet path and makes the network design more explicit about how private resources access AWS services.

---

## Question 6

### Why did Step 23 rediscover the VPC by tag instead of reusing `$VPC_ID` after restarting Floci?

Reusing `$VPC_ID` after the Floci restart would only prove that the Bash shell still remembered the text stored in the variable. A shell variable can continue to contain a value even if the resource represented by that value has disappeared.

For example, `$VPC_ID` could still contain `vpc-123...` even if Floci had restarted in memory-only mode and the actual VPC no longer existed.

Step 23 therefore queried the API again and searched for the VPC using its `Name=usms-vpc` tag. Successfully receiving the VPC ID from a new API request demonstrated that the resource itself survived the restart.

The lab also compared the subnet and security-group counts before and after restart. This provided stronger evidence because a surviving VPC with missing dependent resources would still represent a failed persistence configuration.

This follows the same principle established in Lab 01: persistence should be demonstrated by creating state, disturbing the environment and then reading the actual state back from the service rather than trusting a previously stored value.

---

## Question 7

### Floci does not enforce security groups. How can the rules still be verified?

Although Floci does not enforce security groups against real network packets, the configuration itself can still be inspected through the AWS-compatible API.

For example, after creating `usms-app-sg`, I can use `describe-security-groups` or `describe-security-group-rules` to confirm that the intended TCP ports and sources are stored. Similarly, `usms-db-sg` can be inspected to verify that its PostgreSQL TCP 5432 rule references `usms-app-sg`.

This allows the practical to verify configuration correctness even though it cannot demonstrate a real packet being accepted or dropped.

One specific mistake that the Lab 02 verification script can detect is configuring the database security group with a CIDR source instead of referencing `usms-app-sg`. The verification script explicitly checks that the application's security-group ID appears in the database rule.

A mistake it cannot fully detect is whether the rules would actually allow or block the intended traffic during real packet forwarding. Floci stores the security-group rules but does not enforce them against traffic. Therefore, successful configuration read-back proves that the intended rule exists, but not that Floci has reproduced the complete packet-enforcement behaviour of real AWS.

---

# Conclusion

The review questions demonstrate that the most important concepts from Lab 02 are not simply the AWS CLI commands but the reasoning behind the network design.

The practical showed that subnet connectivity is controlled by routing, security groups and NACLs perform different security roles, group references are more flexible than hard-coded addresses, private outbound access depends on NAT placement, service endpoints change traffic paths and infrastructure persistence must be proven by reading real state back after a restart.