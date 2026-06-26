# Ecommerce Infrastructure — Troubleshooting Log

## Overview

Terraform stack: `infra-ecommerce-aws` repo  
Target: AWS EKS + RDS + VPC (us-east-1)  
GitHub Actions OIDC Role: `arn:aws:iam::986314681697:role/ecommerce-github-actions-role`

---

## Bug #1 — OIDC Auth: `Not authorized to perform sts:AssumeRoleWithWebIdentity`

**Root cause:** The IAM role `ecommerce-github-actions-role` did not exist in AWS at all.

**Symptoms:**
```
Error: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**Fix applied:**
- Created IAM role via AWS CLI with correct OIDC trust policy
- Trust policy uses `StringLike` wildcard: `repo:Srikanthshree/*:*`
- Both actions added: `sts:AssumeRoleWithWebIdentity` + `sts:TagSession` (v4 requires TagSession)
- `AdministratorAccess` policy attached (Terraform needs broad permissions)

**Trust policy (in AWS IAM):**
```json
{
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:Srikanthshree/*:*" }
  }
}
```

---

## Bug #2 — Terraform fmt check failing

**Root cause:** `terraform fmt -check -recursive` in the pipeline detected unformatted files (spacing, indentation).

**Fix applied:**
- Ran `terraform fmt -recursive` locally on all `.tf` files
- Committed the reformatted versions

---

## Bug #3 — Security Group description: non-ASCII characters

**Error:**
```
Error: creating Security Group (ecommerce-eks-cluster-sg): 
api error InvalidParameter: GroupDescription is invalid. 
Character sets beyond ASCII are not supported.
```

**Root cause:** Em-dash characters (`—`) were used in `description` fields of `aws_security_group` resources. AWS EC2 API only accepts ASCII.

**Files fixed:** `modules/eks/main.tf`  
**Fix:** Replaced all `—` with `-` in resource `description` attributes.

> **Note:** Em-dashes in `output {}` and `variable {}` block descriptions are fine — those are Terraform metadata only and never sent to AWS APIs.

---

## Bug #4 — `GITHUB_ORG` variable not allowed

**Error:** GitHub Actions repository variable starting with `GITHUB_` is a reserved prefix.

**Fix applied:** Removed `TF_VAR_github_org` env var from pipeline entirely.  
The Terraform variable `github_org` already has `default = "Srikanthshree"` in `variables.tf` — no GitHub variable needed.

---

## Bug #5 — RDS Parameter Group already exists

**Error:**
```
DBParameterGroupAlreadyExists: Parameter group ecommerce-pg15-params already exists
```

**Root cause:** Previous failed Terraform apply created the parameter group in AWS but the state file was not updated consistently (state was saved from an older run).

**Fix applied:**
- Deleted `ecommerce-pg15-params` from AWS manually (previous runs)
- Later run created it fresh and it is now tracked in state (serial 9)

---

## Bug #6 — EKS Node Group CREATE_FAILED (nodes cannot join cluster)

**Error:**
```
Error: waiting for EKS Node Group (ecommerce-eks:ecommerce-node-group) create:
unexpected state 'CREATE_FAILED', wanted target 'ACTIVE'.
last error: failed to join the kubernetes cluster

AsgInstanceLaunchFailures: Client.InvalidKMSKey.InvalidState:
The KMS key provided is in an incorrect state
```

**Root cause — TWO issues:**

1. **Wrong KMS key for EBS encryption:**  
   The launch template used `aws_kms_key.eks_secrets.arn` for EBS volume encryption. The `eks_secrets` key policy only allows the root account — it does NOT grant EC2 service permission to use the key for EBS encryption. EC2 instances failed to launch because they could not encrypt/decrypt their root EBS volume.

2. **Cluster SG had no ingress rule on port 443:**  
   The `aws_security_group.eks_cluster` had only an egress rule. For nodes to reach the private EKS API endpoint (bootstrap/join), they need port 443 inbound to the cluster SG. Without it, nodes cannot communicate with the control plane.

**Fixes applied in `modules/eks/main.tf`:**

1. Removed `kms_key_id = aws_kms_key.eks_secrets.arn` from launch template EBS block.  
   Used `encrypted = true` alone → AWS uses the default `alias/aws/ebs` key which automatically has correct service permissions.  
   The `eks_secrets` KMS key is for **etcd secrets encryption only** (not EBS).

2. Added `data "aws_vpc" "this"` lookup and added ingress rule on port 443 from VPC CIDR to cluster SG:
   ```hcl
   ingress {
     description = "Nodes to private API server (port 443)"
     from_port   = 443
     to_port     = 443
     protocol    = "tcp"
     cidr_blocks = [data.aws_vpc.this.cidr_block]
   }
   ```
   Using VPC CIDR avoids circular SG reference (`eks_nodes` already references `eks_cluster` in its inline rules).

**Manual cleanup done:**
- Deleted failed node group from AWS: `aws eks delete-nodegroup --cluster-name ecommerce-eks --nodegroup-name ecommerce-node-group`
- Deleted old launch template from AWS (new one will be created with name_prefix)
- Removed from Terraform state: `terraform state rm module.eks.aws_eks_node_group.this`
- Removed from Terraform state: `terraform state rm module.eks.aws_launch_template.eks_nodes`
- Re-imported cluster SG into state: `terraform import module.eks.aws_security_group.eks_cluster sg-07e78ab9a47348c82`

---

## ALB — Not Created by Terraform (by design)

The ALB is **not** created by Terraform. It is created dynamically by the **AWS Load Balancer Controller** running inside EKS.

**Steps to get ALB:**
1. ✅ Infra pipeline runs → EKS cluster + nodes ready
2. Install AWS Load Balancer Controller:
   ```bash
   helm repo add eks https://aws.github.io/eks-charts
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=ecommerce-eks \
     --set serviceAccount.create=true \
     --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<IRSA_ROLE>
   ```
3. App pipeline runs → deploys pods + applies `k8s/ingress.yaml`
4. ALB Controller watches Ingress → creates ALB automatically

---

## Current Infrastructure State (after Bug #6 fix)

| Resource | Status | Notes |
|----------|--------|-------|
| VPC, Subnets, IGW | ✅ Active | 10.0.0.0/16 |
| VPC Endpoints (7) | ✅ Active | ECR, STS, EC2, Logs, SM, ELB + S3 |
| KMS Key (etcd) | ✅ Active | alias/ecommerce-eks-secrets |
| ECR Repos (3) | ✅ Active | backend, frontend, catalog |
| IAM Roles | ✅ Active | cluster, nodes, IRSA, monitoring |
| EKS Cluster | ✅ ACTIVE | ecommerce-eks, v1.30 |
| EKS Node Group | ⏳ To be created | Will be created on next apply with fixes |
| RDS Instance | ⏳ To be created | Waiting on node group completion |
| ALB | ❌ Not TF resource | Created by ALB Controller after app deploy |

---

## Next Steps After Successful Apply

1. Configure `kubectl`: `aws eks update-kubeconfig --name ecommerce-eks --region us-east-1`
2. Get Terraform outputs: `terraform output` (get `app_irsa_role_arn`, `db_secret_arn`, `ecr_backend_url`)
3. Install AWS Load Balancer Controller (see ALB section above)
4. Set GitHub Secrets in app repo: `IRSA_ROLE_ARN`, `DB_SECRET_ARN`
5. Run app pipeline → deploys backend, frontend, catalog
