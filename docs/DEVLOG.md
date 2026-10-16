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
