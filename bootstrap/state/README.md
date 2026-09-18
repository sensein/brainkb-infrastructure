# OpenTofu state backend bootstrap

Creates the S3 bucket + DynamoDB table that hold OpenTofu state for the rest
of the BrainKB infrastructure. **Run this once, ever.** After it succeeds,
every other environment's `backend.hcl` points at the resources it creates.

## What's in here

- `versions.tf` — OpenTofu ≥ 1.7 and AWS provider version pins.
- `variables.tf` — region, bucket name, lock-table name. All have defaults;
  the bucket name must be globally unique across AWS.
- `main.tf` — the resources:
  - S3 bucket with versioning enabled (state history recoverable).
  - Server-side encryption (SSE-S3 / AES-256).
  - Public access blocked at every knob.
  - Bucket policy denying unencrypted uploads and non-TLS access.
  - DynamoDB table for state locking, with point-in-time recovery on.
- `outputs.tf` — bucket name, table name, region — the values that other
  environments' `backend.hcl` needs.

## One-time run

Prerequisites: OpenTofu ≥ 1.7, AWS credentials with permission to create
S3 buckets and DynamoDB tables in the target account.

    cd bootstrap/state
    tofu init
    tofu plan
    tofu apply

State for **this** module lives in a local `terraform.tfstate` file next to
the code. That file is gitignored. Store it somewhere durable and secure
(1Password, an encrypted backup, an existing ops vault) — losing it means
losing the ability to manage the backend resources through tofu, and
recreating them requires either importing or deleting-and-recreating the
bucket (which needs it to be empty first).

## Referencing from other environments

Every environment under `tofu/environments/<name>/` gets a `backend.hcl`
pointing here. Example (fill in with real bucket name after the initial
apply):

    bucket         = "sensein-brainkb-tofu-state"
    key            = "brainkb/<name>/tofu.tfstate"
    region         = "us-east-2"
    dynamodb_table = "sensein-brainkb-tofu-locks"
    encrypt        = true

Then `tofu init -backend-config=backend.hcl` in that environment picks it up.
Different environments (sandbox, production) get different `key` values so
their state files stay independent, but share the bucket and lock table.

## Deliberately not included

- **Customer-managed KMS key.** SSE-S3 (AES-256) is on. If we later want a
  CMK for stricter key control, it's a one-resource addition.
- **Cross-account trust.** State lives in the same AWS account as the
  managed resources for now. Splitting to a separate ops account is a real
  step up in safety but a separate change.
- **Native OpenTofu state encryption** (post-1.7 feature). Not enabled as a
  first step — S3 SSE + IAM already covers the threat model for a
  single-team deploy. Worth revisiting if state ever needs to leave AWS.

## Not the same as `bootstrap.md`

The root-level `bootstrap.md` documents **manual** one-time AWS setup that
hasn't been codified yet (FSx creation, ALB manual clicks, DNS records).
This `bootstrap/state/` directory is **codified** one-time setup for
OpenTofu itself. They're both "run once" but one is a runbook and the
other is `.tf` code.
