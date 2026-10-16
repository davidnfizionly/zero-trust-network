# Development Log

Real problems, in the order they happened: what happened, root cause, fix.

## 2026-10-16 - The original workload no longer deploys as it was

- **What happened:** A plan of the original cluster stack, run from a copy with local state, validated and planned 77 resources, but the configuration asks for Kubernetes 1.30.
- **Root cause:** `aws eks describe-cluster-versions` in us-east-1 no longer lists 1.30. The oldest available version is 1.31, in extended support. The plan does not check the version, so the error would only show at apply.
- **Fix:** The minimum change for the baseline: Kubernetes 1.35 and the AL2023 node AMI (ADR-001). Everything else stays as it was.

## 2026-10-16 - The first version of the pre-push hook let a leak through

- **What happened:** On a test commit containing a sample IAM role ARN, the hook printed `BLOCKED` and the push still succeeded (exit code 0).
- **Root cause:** The scanner records a failure in a shell variable, but the scan functions run on the right-hand side of pipelines, which bash runs in subshells. The variable was set in the subshell and lost.
- **Fix:** The failure state now goes to a temporary file that every subshell can write. Retested on six cases: a clean commit is accepted, and a full ARN, a `.tfstate` file, a foreign author e-mail with a co-author trailer, an access key pattern and an assistant name are all refused (exit code 1).

## 2026-10-16 - The account ID rule flagged provider checksums

- **What happened:** The first full audit refused the Terraform provider lock file.
- **Root cause:** The rule matched any run of 12 digits, and the hexadecimal provider hashes contain such runs between letters.
- **Fix:** A 12-digit number now only matches when it is not touching a letter or digit (the way account IDs appear in ARNs, ECR hostnames and quoted values), and the known account IDs are matched literally anywhere. Retested: the lock file passes, a sample ARN is still refused.

## 2026-10-16 - The e-mail rule flagged Python decorators

- **What happened:** The push of the baseline code was refused for "e-mail address" on FastAPI decorators such as `@app.get`.
- **Root cause:** The audit scans added diff lines, which start with `+`, and the e-mail rule accepted `+` as a one-character local part, so `+@app.get` matched.
- **Fix:** The local part must start with a letter or digit. Retested: decorators pass, a sample address on example.com is still refused.

## 2026-10-16 - Two working copies pushed diverging versions of the zero trust stack

- **What happened:** A push was refused as non-fast-forward: another working copy of the repository had pushed a different implementation of `infra/zerotrust` to `main` in the meantime.
- **Root cause:** Two working copies were writing the same branch at the same time with no coordination.
- **Fix:** The other commit was reverted with a normal revert commit (history not rewritten, no force push) and the validated version was pushed on top. Only one working copy writes to the repository and runs Terraform from then on. Nothing had been deployed: the state bucket was empty and no cluster, firewall or NAT gateway existed.

## 2026-10-16 - The first baseline apply only created the data stack

- **What happened:** The data and cluster stacks were applied in parallel from one shell command. The data stack finished (14 resources); the cluster apply never started.
- **Root cause:** The command set a shell variable for the log directory inside the part sent to the background, so the foreground part redirected the cluster output to a path at the filesystem root, which the shell could not create. Terraform was never launched; the saved plan stayed valid.
- **Fix:** The cluster plan was applied on its own. About 5 minutes lost, nothing to clean up.

## 2026-10-16 - The first external scan under-reported open ports

- **What happened:** The first "before" scan reported the public EKS API with no open port and gave different results for the two addresses of the same load balancer (five open ports on one, only port 80 on the other).
- **Root cause:** The scanner opened 300 connections in parallel with a 2-second timeout. From WSL, that many simultaneous handshakes were dropped or timed out, so listening ports looked closed. Probing the same ports one at a time showed 443 open on the EKS API and 80, 443, 15021 open on both load balancer addresses.
- **Fix:** 64 parallel probes, a 3-second timeout, and a second pass on every port that did not answer; a port counts as open if either pass completes the handshake. The rerun gives the same open ports on both load balancer addresses. The unreliable first output was discarded, not published. The load balancer name, which identifies the resource, is now masked as well.

## 2026-10-16 - The DynamoDB Streams endpoint cannot use private DNS

- **What happened:** The zero trust apply stopped on `InvalidParameter: Private DNS can't be enabled because the service com.amazonaws.us-east-1.dynamodb-streams does not provide a private DNS name`. The firewall, routing and the other endpoints were already created, so the fraud detection service started getting `AccessDeniedException` on `GetRecords`: its calls still left through the NAT path, and the new deny-outside-VPC condition on its role refused them.
- **Root cause:** Not every interface endpoint service publishes a private DNS name. DynamoDB Streams does not, so the public hostname keeps resolving to public addresses inside the VPC.
- **Fix:** The Streams endpoint is created without private DNS, and the fraud detection service gets `AWS_ENDPOINT_URL_DYNAMODB_STREAMS` set to the endpoint's own DNS name (a standard AWS SDK setting, no code change), through a new `extraEnv` value in the Helm chart filled by `workloads/deploy.sh` from a Terraform output. After the redeploy the stream polling loop runs without errors.

## 2026-10-16 - One node was missing from Session Manager for a while

- **What happened:** After the retrofit only one of the two nodes appeared online in Session Manager. The firewall logged a blocked outbound TLS connection without SNI from the other node, through the NAT path, about once a minute.
- **First explanation, later corrected:** The SSM agent was assumed to be stuck because it started before the node role had the Session Manager policy. A reboot to confirm was refused and not run.
- **What the evidence shows:** About 40 minutes later both nodes were online without any reboot, and the once-a-minute blocked connections stopped right after the egress rule fix below (drop rules firing before the SNI was parsed). The node was most likely retrying a connection to an allowlisted destination that the faulty rule dropped. Which process made those connections was not identified.
- **Fix:** The demo scripts select a node that is online in Session Manager; no change was needed once the rule was fixed.

## 2026-10-16 - The egress allowlist blocked the allowlisted registry too

- **What happened:** The blocked-path test showed `https://example.com/` blocked as intended, but `https://registry-1.docker.io/v2/`, which is on the allowlist, was blocked as well. The alert record for it had `app_proto: tls`, `ts_progress: client_in_progress` and no SNI.
- **Root cause:** In strict order, the explicit `drop tls` rule matched the first packets of the connection, before the Client Hello had been parsed, so the SNI-based pass rule never had a chance. The AWS documentation notes that a default drop action can likewise apply to a single packet before application-layer data spanning several packets is available.
- **Fix:** The policy default actions moved to `aws:drop_established_app_layer` and `aws:alert_established_app_layer`, which let a segmented Client Hello through until the SNI is visible, and the explicit TLS and HTTP drop rules now require the SNI, host or URI to be parsed (`tls.sni; content:"."`, `http.host; content:"."`, `http.uri; content:"/"`). Retested: the Docker Hub registry answers (HTTP 401 and 200), `example.com` is blocked.

## 2026-10-16 - The flow log query was rejected, and filtered on the wrong address

- **What happened:** The first run of the DynamoDB private path demo returned no result: every CloudWatch Logs Insights query failed with `MalformedQueryException: Ephemeral field is already defined: bytes`, and the script kept retrying for 16 minutes.
- **Root cause:** CloudWatch Logs already defines fields such as `bytes` for flow log groups, so parsing into the same names is rejected. A second mistake would have hidden the result anyway: the query filtered on pod addresses, but the VPC CNI translates pod traffic leaving the VPC CIDR to the node's primary address, so DynamoDB flows carry the node address as packet source.
- **Fix:** Parsed fields are prefixed (`f_bytes`, `f_start`, ...), the filter uses the addresses of the nodes running the wallet and transaction pods, and the script stops at the first rejected query. The query was tested on existing records before the demo was run again; the rerun shows DynamoDB traffic with `traffic-path` 7 (gateway endpoint).

## 2026-10-16 - Dashboard fixes found by checking the captures

- **What happened:** The automated captures showed four defects: the firewall control failed because it looked for the old default action name; the blocked feed showed the oldest events instead of the newest; the firewall's own endpoint service ID and some IPv6 addresses were displayed unmasked; and Security Hub's 100 most recent findings were all firewall findings, hiding GuardDuty.
- **Root cause:** A hard-coded action name; `FilterLogEvents` returns the oldest events first and only the first page was read; the masking rules covered IPv4 and resource IDs but not `vpce-svc-` IDs or IPv6; one findings query for all sources.
- **Fix:** Prefix match on the default action, pagination through the alert log, masking for endpoint service IDs and IPv6 (four or more groups, so clock times are untouched), one findings query per source, and identical findings grouped with a count. The headless check now also fails on those identifier patterns.
