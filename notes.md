# Sandbox ALB + cert + DNS setup — manual runbook

Working notes for setting up sandbox's public domain access on AWS, written as we go
so this is repeatable later (e.g. for consolidating production onto the same pattern).
Region: **us-east-2**.

## Decisions made

- **One ALB, three domains**, using host-based routing rules — not one ALB per domain
  like production currently has. Same domain names as production would use, but
  consolidated onto fewer, cheaper AWS resources. If this works well, it's also the
  target pattern to eventually migrate production onto (production currently uses 3
  separate ALBs, confirmed via DNS — each of `beta.`/`usermanagement.`/`mlservice.
  brainkb.org` resolves to a different set of IPs).
- **Domains** (mirroring production's naming, without "beta" — just "sandbox" for the UI):
  - `sandbox.brainkb.org` → UI (port 13000)
  - `usermanagement.sandbox.brainkb.org` → usermanagement_service (port 18004)
  - `mlservice.sandbox.brainkb.org` → ml_service (port 18007)
  - `query_service` stays on direct host:port, no domain — matches production's own
    pattern (query_service isn't domained there either).
- **One ACM certificate** covering all 3 domain names, rather than 3 separate certs —
  simpler to manage, attaches to the single ALB just as easily.

## Found along the way

- `sandbox.brainkb.org` already had a Route53 **A record** (not alias) pointing at a
  plain IP, `192.2.0.233` — confirmed unreachable (`curl`: "Network is unreachable").
  Looks like a stale/abandoned leftover from an earlier attempt, not anything live
  today. **Will need to be edited (not freshly created) once our ALB exists** — Route53
  won't allow a duplicate record name. Worth mentioning to Tek at some point, not urgent.

## Steps completed so far

1. **Confirmed AWS region**: us-east-2 (top-right of console).
2. **Certificate Manager → Request a certificate → Request a public certificate**:
   - Domain names added: `sandbox.brainkb.org`, `mlservice.sandbox.brainkb.org`,
     `usermanagement.sandbox.brainkb.org`
   - Validation method: **DNS validation**
   - Key algorithm: default (RSA 2048)
   - **"Allow export": left unchecked** — not needed since this cert is only used by
     an ALB (a fully ACM-integrated service); exportable certs can also incur extra
     cost with no benefit here.
   - Clicked **Request**.
3. On the certificate's detail page, clicked **"Create records in Route 53"** — this
   auto-created the validation CNAME record for all 3 domains in one action (since
   `brainkb.org`'s hosted zone is in this same AWS account).
4. Waited a few minutes for DNS propagation + ACM's re-check. All 3 domains now show
   **validation status: Success**.

5. **Created 3 target groups** (Application Load Balancer type, Instance target type,
   HTTP), one per backend port, all in `vpc-056bce0f8a2a73bfe`:
   - `sandbox-ui-tg` — port 13000
   - `sandbox-usermanagement-tg` — port 18004
   - `sandbox-mlservice-tg` — port 18007
   All 3 registered the EC2 instance (`i-02f4d763f21e415f0`) as their target — showed
   "Unused" health status, expected since no ALB existed yet at that point.
   - Note: found a naming gotcha — AWS target group names don't allow underscores,
     only letters/numbers/hyphens.
   - Side finding: production already has its own `usermanagement-tg` (port 80)
     attached to an ALB named `usermanagement-lb-for-globus` — confirms production's
     one-ALB-per-domain pattern, and that this particular one exists because Globus
     OAuth needs a real HTTPS callback domain.
6. **Created a dedicated security group** `sandbox-alb-sg` (`sg-02e6912482926898b`) for
   the ALB, rather than reusing the VPC's shared `default` security group (to avoid any
   inbound rule we add here also applying to other resources sharing `default`).
   Inbound: TCP 443 and TCP 80, both from `0.0.0.0/0` (Anywhere-IPv4) — expected/required
   for a public-facing web load balancer, despite AWS's generic "restrict to known IPs"
   warning (that warning is much more relevant to things like SSH than public HTTPS).
   Outbound: left on the default "all traffic" rule.
7. **Created the ALB**: `sandbox-alb`, Internet-facing, VPC `vpc-056bce0f8a2a73bfe`,
   2+ AZs, security group `sandbox-alb-sg` (not `default`).
   - Listener: HTTPS : 443, certificate = the one covering all 3 sandbox domains.
   - Pre-routing action: none (no ALB-level auth/JWT validation — usermanagement_service
     already handles OAuth + JWT itself; adding it at the ALB too would be redundant/
     conflicting).
   - Default routing action: forward to `sandbox-ui-tg` only (this is the fallback for
     any request that doesn't match a more specific host-based rule — implicitly covers
     `sandbox.brainkb.org` itself, so no explicit rule is strictly needed for that one).
   - Secure listener settings (TLS security policy): left on AWS default.
   - **Successfully created.**

## Steps still to do

7a. Add 2 more listener rules on the HTTPS:443 listener (host-header conditions):
   - Host = `usermanagement.sandbox.brainkb.org` → forward to `sandbox-usermanagement-tg`
   - Host = `mlservice.sandbox.brainkb.org` → forward to `sandbox-mlservice-tg`
7b. Point DNS at the new ALB:
   - **Edit** the existing `sandbox.brainkb.org` A record → change to an ALIAS
     pointing at the new ALB's DNS name (can't create a duplicate record name).
   - **Create** new ALIAS records for `usermanagement.sandbox.brainkb.org` and
     `mlservice.sandbox.brainkb.org`, also pointing at the same ALB.
8. Check/update security groups: the ALB needs inbound 443 from the internet, and
   the EC2 instance needs to accept traffic from the ALB's security group on ports
   13000/18004/18007.
9. Deploy the UI via PM2 on the EC2 instance (separate checkout from production's,
   same pattern as the backend), `.env.local` pointing at these real domains instead
   of localhost.
10. Update OAuth app redirect URIs (GitHub/ORCID/Globus) to include
    `https://usermanagement.sandbox.brainkb.org/api/auth/<provider>/callback` if you
    want real login to work end-to-end.
