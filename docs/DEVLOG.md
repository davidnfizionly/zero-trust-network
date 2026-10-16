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
