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

## Steps still to do

5. Create 3 target groups (Application Load Balancer type), one per backend port:
   - UI: port 13000
   - usermanagement_service: port 18004
   - ml_service: port 18007
   Each registers the EC2 instance itself as the target.
6. Create the ALB itself:
   - HTTPS:443 listener, using the now-issued certificate.
   - 3 host-based routing rules (one per domain), each forwarding to its
     corresponding target group above.
   - (Consider also an HTTP:80 → HTTPS:443 redirect listener.)
7. Point DNS at the new ALB:
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
