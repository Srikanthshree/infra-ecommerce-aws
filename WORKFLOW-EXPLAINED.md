# GitHub Actions Workflow — Line-by-Line Explanation
# File: .github/workflows/terraform.yml
# ============================================================
# PURPOSE: This pipeline validates, plans, and applies Terraform
#          infrastructure to AWS using OIDC (no stored AWS keys).
# ============================================================

## ─────────────────────────────────────────────────────────────
## SECTION 1 — PIPELINE NAME & TRIGGER
## ─────────────────────────────────────────────────────────────

```yaml
name: "Terraform Infrastructure CI/CD (OIDC debug)"
```
► The display name shown in GitHub Actions tab.

```yaml
on:
  push:
    branches: ["main"]     # runs when code is pushed to main branch
  pull_request:
    branches: ["main"]     # runs when a PR is opened/updated targeting main
```
► Defines WHEN the pipeline triggers.
► Both push and pull_request events trigger this pipeline.
► Pull requests only run iac-security-scan + terraform-plan (NOT apply).
► Apply only runs on push to main (controlled later with an `if:` condition).

---

## ─────────────────────────────────────────────────────────────
## SECTION 2 — GLOBAL PERMISSIONS
## ─────────────────────────────────────────────────────────────

```yaml
permissions:
  contents: read       # allows reading repo code (git checkout)
  id-token: write      # CRITICAL — allows requesting OIDC token from GitHub
```
► `id-token: write` is REQUIRED for OIDC to work.
► Without it, GitHub will NOT issue the JWT token needed to authenticate with AWS.
► This is the global default; each job can override it.

---

## ─────────────────────────────────────────────────────────────
## SECTION 3 — CONCURRENCY CONTROL
## ─────────────────────────────────────────────────────────────

```yaml
concurrency:
  group: terraform-${{ github.ref }}   # one pipeline per branch at a time
  cancel-in-progress: false            # do NOT cancel a running apply midway
```
► Prevents two pipelines running on the same branch simultaneously.
► `cancel-in-progress: false` is IMPORTANT — if apply is running and another
   push happens, the new run waits instead of killing the running apply.
► Killing a running `terraform apply` mid-way can corrupt state.

---

## ─────────────────────────────────────────────────────────────
## SECTION 4 — GLOBAL ENVIRONMENT VARIABLES
## ─────────────────────────────────────────────────────────────

```yaml
env:
  TF_VERSION: "1.8.5"       # Terraform version to install on the runner
  AWS_REGION: "us-east-1"   # AWS region for all operations
```
► Defined once here, reused throughout all jobs with `${{ env.TF_VERSION }}`.
► Avoids hardcoding the same value in multiple places.

---

## ─────────────────────────────────────────────────────────────
## JOB 1 — iac-security-scan
## PURPOSE: Scan Terraform code for security misconfigurations
##          BEFORE any AWS resource is touched.
## ─────────────────────────────────────────────────────────────

```yaml
  iac-security-scan:
    name: "IaC Security Scan (Trivy + tfsec)"
    runs-on: ubuntu-latest          # use GitHub-hosted Ubuntu runner
    permissions:
      contents: read                # read repo code
      security-events: write        # write results to GitHub Security tab
```
► This job runs FIRST. terraform-plan only starts after this passes.
► `security-events: write` lets us upload SARIF results to GitHub Security tab.

### Step 1 — Checkout
```yaml
      - name: Checkout
        uses: actions/checkout@v4
```
► Downloads the repository code onto the runner.
► Without this, the runner has no files to work with.

### Step 2 — Trivy scan
```yaml
      - name: Trivy — IaC misconfiguration scan
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: "config"         # scan infrastructure-as-code configs
          scan-ref: "."               # scan the entire repo from root
          format: "sarif"             # output in SARIF format (GitHub standard)
          output: "trivy-iac.sarif"   # save results to this file
          severity: "CRITICAL,HIGH"   # only flag CRITICAL and HIGH findings
          exit-code: "0"              # DO NOT fail the pipeline on findings
                                      # (exit-code "1" would fail)
```
► Trivy scans all Terraform files for misconfigurations (open S3 buckets,
   unencrypted disks, public security groups, etc.).
► `exit-code: "0"` means findings are REPORTED but pipeline does not fail.
► Results appear in: repo → Security tab → Code scanning alerts.

### Step 3 — Upload Trivy SARIF
```yaml
      - name: Upload Trivy IaC results → GitHub Security
        uses: github/codeql-action/upload-sarif@v3
        if: always()                    # run even if Trivy step failed
        with:
          sarif_file: "trivy-iac.sarif"
          category: "trivy-iac"
```
► Uploads the SARIF file to GitHub Security tab so findings are visible.
► `if: always()` ensures results are uploaded even if a previous step failed.

### Step 4 — tfsec scan
```yaml
      - name: tfsec — Terraform security analysis
        uses: aquasecurity/tfsec-action@v1.0.3
        with:
          soft_fail: false            # FAILS the pipeline if issues found
          format: sarif               # output SARIF format
          github_token: ${{ secrets.GITHUB_TOKEN }}
```
► tfsec is a second security scanner specifically for Terraform.
► `soft_fail: false` means if tfsec finds HIGH/CRITICAL issues → pipeline FAILS.
► `GITHUB_TOKEN` is auto-provided by GitHub — no setup needed.
► ⚠️  KNOWN ISSUE: If your Terraform has security findings, this step will FAIL
     and terraform-plan will never run. Check: repo → Security → Code scanning.

---

## ─────────────────────────────────────────────────────────────
## JOB 2 — terraform-plan
## PURPOSE: Authenticate to AWS via OIDC, validate Terraform,
##          and generate a plan to show what will change.
## ─────────────────────────────────────────────────────────────

```yaml
  terraform-plan:
    needs: iac-security-scan      # only runs AFTER security scan passes
    permissions:
      id-token: write             # needed to request OIDC token
      contents: read              # needed to checkout code
```

### Step 1 — Checkout
```yaml
      - name: Checkout
        uses: actions/checkout@v4
```
► Downloads repository code onto this new runner.
► Each job runs on a FRESH runner — files from job 1 are NOT available here.

### Step 2 — OIDC Token Debug (diagnostic step)
```yaml
      - name: Debug fetch raw OIDC id token and decode claims
        shell: bash
        run: |
          TOKEN_URL="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com"
```
► `ACTIONS_ID_TOKEN_REQUEST_URL` — GitHub runner injects this automatically.
► It is the URL to request the OIDC JWT token from GitHub's OIDC endpoint.
► `audience=sts.amazonaws.com` tells GitHub who this token is intended for.
► The trust policy in AWS must have `aud: sts.amazonaws.com` to match this.

```yaml
          RAW_JSON=$(curl -sS -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "$TOKEN_URL")
```
► `ACTIONS_ID_TOKEN_REQUEST_TOKEN` — GitHub runner injects this (bearer token
   to authenticate the request to GitHub's OIDC endpoint).
► Makes an HTTPS request to get the JWT token.
► Response is JSON: `{"value": "<JWT_TOKEN_HERE>"}`.

```yaml
          ID_TOKEN=$(printf '%s' "$RAW_JSON" | jq -r '.value')
          printf '%s' "$ID_TOKEN" > id_token.jwt
          chmod 600 id_token.jwt
```
► Extracts just the JWT string from the JSON response.
► Saves it to a file `id_token.jwt` (used in the next diagnostic step).
► `chmod 600` — restricts file to owner only (security best practice).

```yaml
          PAYLOAD_B64=$(printf '%s' "$ID_TOKEN" | cut -d'.' -f2)
          printf '%s' "$PAYLOAD_B64" | tr '_-' '/+' | base64 --decode | jq .
```
► A JWT has 3 parts: `header.payload.signature` — split by dots.
► `cut -d'.' -f2` extracts the middle payload part (base64 encoded).
► `tr '_-' '/+'` converts URL-safe base64 to standard base64.
► `base64 --decode | jq .` decodes and pretty-prints the JSON claims.
► You will see fields like: `sub`, `aud`, `iss`, `repository`, `ref`.
► The `sub` field is what AWS trust policy matches against.

### Step 3 — Direct STS diagnostic
```yaml
      - name: Debug direct aws sts assume-role-with-web-identity (diagnostic)
        env:
          ROLE_ARN: ${{ secrets.AWS_IAM_ARN }}
```
► `secrets.AWS_IAM_ARN` — the IAM Role ARN stored in GitHub Secrets.
► Path: repo → Settings → Secrets and variables → Actions → AWS_IAM_ARN.
► ⚠️  MUST be named exactly `AWS_IAM_ARN` — any other name = empty string = fail.

```yaml
          aws sts assume-role-with-web-identity \
            --role-arn "$ROLE_ARN" \
            --web-identity-token file://id_token.jwt \
            --duration-seconds 900 \
```
► Makes a direct AWS STS API call (bypasses the GitHub Action wrapper).
► This lets you see the EXACT AWS error message before the official action runs.
► `--duration-seconds 900` = 15 minute session (minimum allowed).
► If this fails → error is printed but pipeline continues to the official action.
► If this succeeds → AWS returned temporary credentials successfully.

### Step 4 — Official AWS OIDC action
```yaml
      - name: Configure AWS credentials via OIDC (official action)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_IAM_ARN }}
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: "GitHubActions-TFPlan-${{ github.run_number }}"
```
► The official AWS action that sets up credentials for subsequent steps.
► `role-to-assume` — the ARN of the IAM role to assume via OIDC.
► Under the hood, this action:
     1. Requests OIDC token from GitHub (audience: sts.amazonaws.com)
     2. Calls AWS STS AssumeRoleWithWebIdentity with the token
     3. Receives temporary credentials (AccessKeyId, SecretAccessKey, SessionToken)
     4. Sets them as environment variables for all subsequent steps
► `role-session-name` — appears in AWS CloudTrail logs for audit purposes.
► After this step: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_SESSION_TOKEN` are available in all following steps.
► ⚠️  REQUIRES in AWS Trust Policy:
     - Action: ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]
       (v4 sends 7 session tags — TagSession MUST be allowed)
     - Condition sub must match the job's actual sub claim

### Step 5 — Caller identity debug
```yaml
      - name: Debug AWS caller identity after action
        run: aws sts get-caller-identity --output json
```
► Confirms which IAM role/user is active after OIDC auth.
► Output shows: Account ID, User ID, ARN of the assumed role.
► If you see your role ARN here → OIDC authentication succeeded ✅

### Step 6 — Install Terraform
```yaml
      - name: Setup Terraform ${{ env.TF_VERSION }}
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}   # = "1.8.5"
```
► Downloads and installs Terraform 1.8.5 on the runner.
► Makes the `terraform` CLI available for subsequent steps.

### Step 7 — Format check
```yaml
      - name: Terraform Format Check
        run: terraform fmt -check -recursive
```
► Checks that all `.tf` files are properly formatted.
► `-check` = do NOT reformat, just report if formatting is wrong.
► `-recursive` = check all subdirectories (modules/).
► ⚠️  If any .tf file has bad formatting → this FAILS the pipeline.
► Fix locally: run `terraform fmt -recursive` then commit.

### Step 8 — Terraform Init
```yaml
      - name: Terraform Init
        run: terraform init -input=false
```
► Downloads all provider plugins (AWS ~5.55, TLS, Random) defined in providers.tf.
► Connects to the S3 backend to store/read Terraform state.
► `-input=false` = fail instead of waiting for interactive input.
► ⚠️  REQUIRES these AWS resources to exist BEFORE running:
     - S3 bucket: `ecommerce-application-state-file` (in us-east-1)
     - DynamoDB table: `statefile` (for state locking)
► If these don't exist → terraform init fails with "bucket does not exist".
► YOU MUST CREATE THESE MANUALLY before the pipeline can work.

### Step 9 — Terraform Validate
```yaml
      - name: Terraform Validate
        run: terraform validate
```
► Checks Terraform syntax and configuration consistency.
► Does NOT make any API calls to AWS.
► Catches: missing variables, wrong types, invalid resource attributes.

### Step 10 — Terraform Plan
```yaml
      - name: Terraform Plan
        run: |
          terraform plan \
            -out=tfplan \       # save the plan to a file named "tfplan"
            -no-color \         # no ANSI color codes (cleaner in logs)
            -input=false        # fail if any input is required
        env:
          TF_VAR_github_org: ${{ vars.GITHUB_ORG }}
```
► Compares desired state (your .tf files) vs actual state (in S3) vs real AWS.
► Shows: what will be created (+), destroyed (-), modified (~).
► `-out=tfplan` saves the plan binary — ONLY this exact plan can be applied later.
► `TF_VAR_github_org` — passes the GitHub org name as a Terraform variable.
► `vars.GITHUB_ORG` comes from: repo → Settings → Variables → Actions.
► ⚠️  If `GITHUB_ORG` variable is not set → `github_org` variable in Terraform
     will be empty, may cause validation issues.

### Step 11 — Upload plan artifact
```yaml
      - name: Upload Terraform plan artifact
        uses: actions/upload-artifact@v4
        with:
          name: tfplan
          path: tfplan          # upload the plan binary file
          retention-days: 1     # auto-deleted after 1 day
```
► Saves the plan file so the next job (terraform-apply) can download and use it.
► This ensures apply runs the EXACT same plan that was reviewed — no surprises.
► Without uploading, the plan is lost when this job's runner terminates.

---

## ─────────────────────────────────────────────────────────────
## JOB 3 — terraform-apply
## PURPOSE: Apply the approved plan to create/update real AWS infra.
## ONLY runs on push to main (NOT on pull requests).
## ─────────────────────────────────────────────────────────────

```yaml
  terraform-apply:
    needs: terraform-plan          # only runs AFTER plan succeeds
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
```
► Double guard: must be main branch AND must be a push (not a PR).
► Pull requests will see this job as "skipped" — that is correct behaviour.

```yaml
    environment: production
```
► Links this job to the GitHub "production" environment.
► ⚠️  IMPORTANT: This changes the OIDC sub claim for this job to:
     `repo:Srikanthshree/infra-ecommerce-aws:environment:production`
     (NOT `ref:refs/heads/main` like the plan job).
► AWS trust policy MUST allow this sub — use wildcard:
     `"repo:Srikanthshree/infra-ecommerce-aws:*"`
► You can add protection rules here: required reviewers, wait timer, etc.
► Setup: repo → Settings → Environments → production

### Step 1 — Checkout
```yaml
      - name: Checkout
        uses: actions/checkout@v4
```
► Fresh runner — must checkout code again.

### Step 2 — Print OIDC sub claim (diagnostic)
```yaml
      - name: Print OIDC sub claim (diagnostic)
        run: |
          ... jq '{sub,aud,iss,repository,environment,ref}'
          echo "=== Trust policy must match the sub value above ==="
```
► Prints the EXACT sub claim this job sends to AWS.
► For environment: production jobs, sub will be:
     `repo:Srikanthshree/infra-ecommerce-aws:environment:production`
► Check this in your pipeline logs to confirm what AWS receives.

### Step 3 — AWS OIDC auth (same as plan job)
```yaml
      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_IAM_ARN }}
          role-session-name: "GitHubActions-TFApply-${{ github.run_number }}"
```
► Same OIDC auth as the plan job, but with a different session name.
► Session name helps distinguish plan vs apply in CloudTrail audit logs.

### Step 4 — Install Terraform (again)
```yaml
      - name: Setup Terraform ${{ env.TF_VERSION }}
```
► Fresh runner again — Terraform must be installed again.

### Step 5 — Terraform Init (again)
```yaml
      - name: Terraform Init
        run: terraform init -input=false
```
► Must run init again on this fresh runner to download providers and
  connect to S3 backend before applying.

### Step 6 — Download plan artifact
```yaml
      - name: Download Terraform plan artifact
        uses: actions/download-artifact@v4
        with:
          name: tfplan
          path: .              # download to the current directory (repo root)
```
► Downloads the `tfplan` binary file that was created in the plan job.
► The apply step will use exactly this plan — nothing can change between
  plan and apply.

### Step 7 — Terraform Apply
```yaml
      - name: Terraform Apply
        run: terraform apply -auto-approve -input=false tfplan
```
► Executes the saved plan against real AWS infrastructure.
► `-auto-approve` = no interactive confirmation prompt.
► `tfplan` = use the downloaded plan file (not generate a new one).
► This creates/modifies/destroys real AWS resources.

---

## ═══════════════════════════════════════════════════════════════
## PIPELINE FLOW DIAGRAM
## ═══════════════════════════════════════════════════════════════

```
PUSH TO MAIN:
  [iac-security-scan] → [terraform-plan] → [terraform-apply]
       Trivy + tfsec      OIDC auth          OIDC auth
       security scan      tf init            tf init
                          tf validate        tf apply
                          tf plan
                          upload artifact

PULL REQUEST:
  [iac-security-scan] → [terraform-plan] → [terraform-apply: SKIPPED]
```

---

## ═══════════════════════════════════════════════════════════════
## PREREQUISITES — WHAT MUST EXIST BEFORE PIPELINE CAN PASS
## ═══════════════════════════════════════════════════════════════

### In AWS (must be manually created):

| Resource | Name | Why needed |
|----------|------|-----------|
| S3 Bucket | `ecommerce-application-state-file` | Terraform remote state storage |
| DynamoDB Table | `statefile` | Terraform state locking (prevents concurrent applies) |
| IAM OIDC Provider | `token.actions.githubusercontent.com` | Links GitHub to AWS |
| IAM Role | any name | Role GitHub assumes via OIDC |

### IAM Role Trust Policy (copy exactly):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::986314681697:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": [
      "sts:AssumeRoleWithWebIdentity",
      "sts:TagSession"
    ],
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:Srikanthshree/infra-ecommerce-aws:*"
      }
    }
  }]
}
```

### In GitHub Secrets (repo → Settings → Secrets and variables → Actions):

| Secret Name | Value | Where used |
|------------|-------|-----------|
| `AWS_IAM_ARN` | `arn:aws:iam::986314681697:role/<your-role-name>` | OIDC role assumption |

### In GitHub Variables (repo → Settings → Secrets and variables → Actions → Variables tab):

| Variable Name | Value | Where used |
|--------------|-------|-----------|
| `GITHUB_ORG` | `Srikanthshree` | Passed as `TF_VAR_github_org` to Terraform |

### In GitHub Environments (repo → Settings → Environments):
- Create environment named: `production`
- (Optional) Add required reviewers for manual approval before apply

---

## ═══════════════════════════════════════════════════════════════
## COMMON FAILURE POINTS AND HOW TO DIAGNOSE
## ═══════════════════════════════════════════════════════════════

| Step failing | Error message | Root cause | Fix |
|-------------|---------------|------------|-----|
| tfsec | `[HIGH] ...` | Security issue in your .tf code | Fix the finding or set `soft_fail: true` |
| Configure AWS credentials | `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy sub mismatch or missing `sts:TagSession` | Update trust policy with wildcard sub + TagSession |
| Configure AWS credentials | Secret resolves to empty | Wrong secret name in YAML vs GitHub Secrets | Must be `AWS_IAM_ARN` exactly |
| Terraform Init | `bucket does not exist` | S3 backend bucket not created yet | Create S3 bucket `ecommerce-application-state-file` manually |
| Terraform Init | `table not found` | DynamoDB table not created | Create DynamoDB table `statefile` with partition key `LockID` (String) |
| Terraform fmt | `Files are not formatted` | .tf files need formatting | Run `terraform fmt -recursive` locally and commit |
| Terraform Plan | `Error: no valid credential sources` | AWS creds expired or not set | Check configure-aws-credentials step passed |
