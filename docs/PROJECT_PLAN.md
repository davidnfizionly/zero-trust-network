# Zero Trust Network Architecture on AWS - Retrofitting a Real Workload to Eliminate Implicit Trust

---

## Project Description

Most cloud demos start from the same default: public load balancers and public endpoints, reachable from anywhere on the internet, secured only by application-layer controls once a request arrives. That default is the normal starting point, and it is exactly the assumption zero trust architecture exists to remove: no request is trusted because of where it came from, and nothing is reachable simply because a security group happened to allow it.

This project does not build a new workload to prove the point. It retrofits a zero trust network architecture onto an existing, working payment platform - five microservices on Amazon EKS with Istio - removing every point of implicit trust one layer at a time: no public subnet for application workloads, no inbound SSH, no direct internet path to AWS services, all traffic inspected, and every administrative action authenticated and logged rather than assumed. The result is proven, not asserted: an external port scan finds nothing to connect to except one deliberate entry point, an unauthorized path is actively blocked and logged, and an administrator reaches a private instance with zero open inbound ports. A before and after comparison, measured against the original network posture, shows what changed.

---

## Technologies & Services Used

| Layer | Technology | Purpose |
| --- | --- | --- |
| IaC | **Terraform** | All network and security configuration - single source of truth |
| Network segmentation | **Amazon VPC**, private-only subnets for application workloads | Removes the public-by-default assumption at the network layer |
| Traffic inspection | **AWS Network Firewall** | Stateful inspection of traffic in and out of the VPC, not just security group allow-lists |
| Private access to AWS services | **VPC Endpoints (AWS PrivateLink)** | DynamoDB, ECR, Secrets Manager reachable without traversing the public internet |
| Administrative access | **AWS Systems Manager Session Manager** | Shell access to any instance with zero open inbound ports - no bastion host, no exposed SSH |
| Threat detection | **Amazon GuardDuty** | Managed threat detection across the account |
| Security findings | **AWS Security Hub** | Aggregated view of the account's security posture |
| Identity-aware access control | **IAM conditional policies** | Requests are evaluated against context (source, identity, resource), not just a static allow rule |
| Workload | **Payment platform** (EKS, Istio, 5 microservices) | The real system being retrofitted |
| Frontend | **React** | Security posture dashboard |

---

## Architecture Patterns Actually Demonstrated

- **Default-deny network posture** - application workloads live in private subnets with no route to the public internet; access exists only where explicitly provisioned.
- **Traffic inspection as a first-class control** - AWS Network Firewall inspects traffic rather than relying solely on security group allow-lists, which control reachability, not content.
- **Private service access without public exposure** - VPC Endpoints mean the platform's services talk to DynamoDB, ECR and Secrets Manager without touching the public internet.
- **No standing administrative access** - Session Manager replaces SSH and bastion hosts; no port is permanently open for human access, and every session is logged.
- **Continuous verification over one-time perimeter trust** - IAM conditional policies and GuardDuty mean trust is evaluated per request and monitored continuously.
- **Retrofitting a real system** - the controls are proven against a working workload and its real traffic, with a measured before and after.

---

## Demo Scenarios

| Scenario | What Happens | What It Proves |
| --- | --- | --- |
| **External port scan** | A port scan run from outside the VPC against the platform's public-facing surface | Nothing is reachable except the single, deliberately exposed ingress point |
| **Blocked unauthorized path** | A request attempting to reach a service directly, bypassing the intended traffic path | Network Firewall blocks and logs it, visible on the dashboard |
| **Zero-open-port admin access** | An administrator connects to a private instance or EKS node via Session Manager | A full, logged shell session with no inbound port opened on that instance |
| **Private AWS service call proof** | A trace of a request from a microservice to DynamoDB | The request path stays on the AWS private network, confirmed by VPC Flow Logs, not just configuration |

---

## UI Details

- **Security posture dashboard** - current state of every control (private subnets, firewall rules, endpoint status, GuardDuty and Security Hub findings)
- **Blocked-attempts panel** - feed of inspected traffic and any blocked attempt, with the reason it was blocked
- **Administrative access log** - every Session Manager session, what instance, how long
- **Plain-language framing** - an attempted connection gets blocked and the reason is readable without parsing firewall rule syntax

---

## Use Case Simulation

| Role | What They'd See/Do in This System |
| --- | --- |
| **Security/platform engineer** | Reviews the aggregated findings and the blocked-attempts feed to assess the real-time security posture |
| **Administrator** | Accesses a private instance via Session Manager, with the full session logged for audit |
| **Auditor/compliance reviewer** | Confirms no inbound ports are open anywhere and no workload has a public IP, from the dashboard and the recorded evidence |
| **External attacker (simulated)** | Port-scans the platform's public surface and finds nothing to exploit beyond the single intended entry point |

---

## Deployment Strategy

1. **Terraform backend**
2. **Baseline** - deploy the workload with its original network layout and measure its posture (public exposure, security group rules, external scan)
3. **Network redesign** - move workloads into private-only subnets
4. **AWS Network Firewall** - explicit allow rules, default deny otherwise
5. **VPC Endpoints** - DynamoDB, ECR, Secrets Manager reachable privately
6. **Remove all direct administrative access** - no SSH or bastion path, Session Manager configured
7. **GuardDuty** enabled
8. **Security Hub** enabled and configured to aggregate findings
9. **IAM conditional policies** - existing workload roles tightened to context-aware, least-privilege conditions
10. **Security posture dashboard**
11. **Demo scenario validation** - all 4 scenarios run and recorded
12. **Documentation and proof** - captures, architecture diagram, before and after comparison
13. **Clean-up** - billed resources torn down and verified

---

## Considered and Rejected

- **Multi-account governance (AWS Organizations, SCPs, Landing Zone)** - a valuable pattern, but it solves a different problem (governance across many accounts) than this project's (eliminating implicit trust inside one workload's network).
- **Third-party ZTNA vendor products** - would demonstrate vendor configuration more than cloud-native architecture skill, and add licensing complexity with no portfolio value over AWS-native controls.
- **AWS Transit Gateway** - solves multi-VPC and multi-account connectivity; this project is a single-VPC retrofit.

---

## Architecture Decisions Worth Documenting

- **Retrofit the existing platform instead of building a new workload**: proving zero trust controls against a real system with real traffic patterns is more credible than designing a workload to make the controls look clean.
- **AWS Network Firewall instead of security groups alone**: security groups control reachability, not content; stateful inspection catches what a simple allow-list cannot.
- **Session Manager instead of a bastion host**: a bastion host is itself a standing, exposed entry point; Session Manager provides the same capability with zero inbound ports.
- **No multi-account governance here**: documented as out of scope rather than included because it is thematically adjacent.
- **Proof over assertion for every claim**: a scan, a blocked-traffic log and a zero-open-port session are each independently verifiable.
