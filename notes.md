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

## Port convention: sandbox port = production port + 10000

No exceptions — applied uniformly so there's never any ambiguity about which port
belongs to which environment on the shared EC2 instance.

| Service              | Production | Sandbox |
|----------------------|-----------:|--------:|
| UI                   |       3000 |   13000 |
| API token manager    |       8000 |   18000 |
| Usermanagement       |       8004 |   18004 |
| ML service           |       8007 |   18007 |
| Query service        |       8010 |   18010 |
| Oxigraph             |       7878 |   17878 |
| pgAdmin              |       5051 |   15051 |
| Postgres             |       5432 |   15432 |

(The UI port briefly broke this rule during early ad-hoc local testing — used 3080
instead of 13000 — fixed once noticed, see commit `68512de`.)

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

7a. **Added 2 more listener rules** on the HTTPS:443 listener, via "Add rule" (not
   "Edit rule" — that would've modified the existing default rule instead):
   - Priority 1: Host header = `usermanagement.sandbox.brainkb.org` → forward to
     `sandbox-usermanagement-tg`
   - Priority 2: Host header = `mlservice.sandbox.brainkb.org` → forward to
     `sandbox-mlservice-tg`
   - Left "Transforms" and "Target group stickiness" alone (not needed); pre-routing
     action "No pre-routing action" on both (same reasoning as the default listener).
   - Final rule list confirmed correct: rule 1 → usermanagement tg, rule 2 → mlservice
     tg, default (last) → `sandbox-ui-tg`.

7b. **Pointed DNS at the new ALB** — Route53 → Hosted zones → `brainkb.org`:
   - **Edited** the existing `sandbox.brainkb.org` A record (the stale one pointing at
     `192.2.0.233`) → toggled Alias: Yes → Alias to Application/Classic Load Balancer →
     `us-east-2` → `sandbox-alb` (the `dualstack.` DNS name — same ALB, just the
     IPv4+IPv6 name AWS shows by default; not a different resource) → Routing policy:
     Simple → Evaluate Target Health: **off** (no failover benefit with a single Simple
     record; leaving it on would make DNS stop resolving entirely whenever a target
     group's health check isn't passing, e.g. before the UI is even deployed).
   - **Created** new alias records the same way for `usermanagement.sandbox` and
     `mlservice.sandbox` (Route53 auto-appends `.brainkb.org` to whatever's typed in
     "Record name" inside this hosted zone — just the subdomain prefix is needed).
   - Verified via `dig`: all 3 domains resolve, and all return the *same* 2 IPs
     (`3.141.226.221`, `3.139.148.61`) — confirms they're genuinely sharing the one
     ALB, unlike production's separate-ALB-per-domain setup.

8. **Updated the EC2 instance's security group** (`launch-wizard-25` /
   `sg-00ae856ca219ae663` — found via the instance's own Security Groups page, not the
   read-only summary under the instance's Security tab, which doesn't have an edit
   button). Added 3 inbound rules, each with **Source: Custom → `sandbox-alb-sg`**
   (not `0.0.0.0/0`) — so only the ALB can reach these ports, not the whole internet:
   - Port `13000`, description "sandbox UI"
   - Port `18004`, description "sandbox oauth callback user management"
   - Port `18007`, description "sandbox ml structsense"
   - Side observation: every one of production's existing rules on this security group
     (including SSH, port 22) is open to `0.0.0.0/0` directly — the one exception is
     the Lustre/FSx rule, restricted to a specific security group. Worth mentioning to
     Tek as a hardening opportunity sometime, not touched/fixed here.

## How to check whether a domain is actually working end-to-end

```
curl -sI --max-time 10 https://usermanagement.sandbox.brainkb.org/
curl -sI --max-time 10 https://mlservice.sandbox.brainkb.org/
```

`-I` sends a HEAD request and only prints the response headers (fast, doesn't download
anything); `--max-time 10` stops it from hanging if something's actually unreachable.

**How to read the result**: any real HTTP response — even a `404` or `405` — means it
worked. That means the request made it all the way through DNS → ALB (TLS handled
correctly) → the ALB's host-based routing rule → the target group → the actual backend
service, and the *service itself* answered. A `404`/`405` just means that specific
path/method isn't defined by the app (e.g. `usermanagement_service`'s root path only
supports GET, not HEAD; `ml_service` has no route at `/` at all) — normal app behavior,
not a routing failure. Look for `server: uvicorn` (or whatever the real backend
announces) in the response headers as the confirming detail — that's the backend
itself speaking, not some earlier layer (ALB, Route53, or a security-group block)
silently swallowing the request.

**What actually indicates a problem**, in contrast: `curl: (28) Connection timed out`
(security group blocking the ALB from reaching the instance, or nothing listening on
that port), `curl: (60) SSL certificate problem` (cert issue), or a `503`/`504` from
the ALB itself (no healthy targets in the target group) — none of which showed up here.

Verified this way for `usermanagement.sandbox.brainkb.org` (405, `allow: GET`) and
`mlservice.sandbox.brainkb.org` (404) — both genuinely working end-to-end, with zero
changes needed on the backend side; the ALB/DNS/security-group setup alone did it.

9. **Deployed the UI via PM2** on the instance — separate checkout from production's:
   ```
   cd ~/sandbox-workspace
   git clone https://github.com/sensein/brainkb-ui.git
   cd brainkb-ui
   cp ../brainkb-infrastructure/sandbox/ui.env.template .env.local
   sed -i 's/<host>/3.13.122.67/g' .env.local   # instance's public IP, for query_service
   sed -i 's/^NEXTAUTH_SECRET=$/NEXTAUTH_SECRET=<a real generated secret>/' .env.local
   PM2_APP_NAME=brainkb-ui-sandbox PORT=13000 bash bin/up-node.sh
   ```
   `ui.env.template` already had the real sandbox domains filled in from earlier work —
   only needed the `<host>` placeholder (for undomained `query_service`/`chat_service`)
   and a real `NEXTAUTH_SECRET`. Left `NEXT_PUBLIC_JWT_USER`/`PASSWORD` blank — login
   won't fully work without them, but wasn't blocking this verification. Build succeeded
   (a few expected cache-warming 403s from the blank JWT creds, and one pre-existing
   unrelated webpack warning about `rdf-canonize-native` — neither blocks the build).
   PM2 process `brainkb-ui-sandbox` came up `online` on port 13000, no collision with
   production's own `brainkb-ui` PM2 process.
   - **Verified**: `curl -sI https://sandbox.brainkb.org/` → `HTTP/2 200`,
     `x-powered-by: Next.js` — full chain confirmed working: DNS → ALB (TLS) →
     target group → PM2.

**All 3 sandbox domains are now genuinely live and working end-to-end**:
`sandbox.brainkb.org`, `usermanagement.sandbox.brainkb.org`, `mlservice.sandbox.brainkb.org`.

## What doesn't work right now because of blank/placeholder secrets

Current `.env` (backend) and `.env.local` (UI) use the smoke-test values from
`sandbox/backend.env.smoketest.example` / `sandbox/ui.env.template` — real domains, but
several credentials deliberately left blank. Concretely, this means:

- **No login at all, for any provider.** `GITHUB_CLIENT_ID/SECRET`,
  `ORCID_CLIENT_ID/SECRET`, `GLOBUS_CLIENT_ID/SECRET` are all blank in the backend
  `.env`. Since "the UI asks the backend which providers are configured and renders
  only those buttons," the login page likely shows **zero** provider buttons, not just
  broken ones. (Globus specifically is why production has a dedicated
  `usermanagement-lb-for-globus` ALB — that flow can't be tested at all yet.)
- **Most data-driven UI pages will show empty/error states.** `NEXT_PUBLIC_JWT_USER`/
  `PASSWORD` (the UI's own service-account credentials for calling the backend) are
  blank. Seen directly during the build: `Failed to get bearer token, proceeding
  without authentication`, followed by `fetch failed` / `API returned 403` for
  statistics, knowledge-base pages, NER, and Resources caches. Any page that needs
  this service-account token to fetch data will likely be empty or show an error,
  even though the pages themselves load fine (HTTP 200).
- **No SuperAdmin exists.** `USERMANAGEMENT_BOOTSTRAP_SUPERADMIN_EMAILS` is blank, so
  nobody gets bootstrapped into the SuperAdmin role on startup.
- **NER features won't work.** `MONGO_DB_URL` is blank — anything backed by
  `NER_DATABASE`/`NER_COLLECTION` (NER get/save) has nowhere to read/write.
- **Weaviate-backed KG source features are off.** `WEAVIATE_API_KEY`/`GRPC_HOST`/
  `HTTP_HOST` blank, and `ENABLE_KG_SOURCE=False` — this is otherwise-intentional for a
  smoke test, not just a side effect of blank values.
- **PDF extraction won't work.** `GROBID_SERVER_URL_OR_EXTERNAL_SERVICE` is blank.
- **SynthScholar's external literature search fan-out is degraded, not broken.**
  `OPENROUTER_API_KEY`, `NCBI_API_KEY`, `SEMANTIC_SCHOLAR_API_KEY`, `CORE_API_KEY` are
  all blank — per their own code comments these are each independently optional and
  silently skipped if absent, so search still runs, just against fewer sources (and
  OpenRouter is only the operator-fallback key anyway; a per-user key would still work
  if supplied through the UI at request time).
- **No centralized logging.** `LOGTAIL_API_KEY` blank — logs stay local to the
  container/host instead of being shipped anywhere.

**What this does NOT affect**: the deployment pipeline itself (DNS, TLS, ALB routing,
security groups, the actual services running and responding) — all of that is fully
confirmed working, independent of any of these credentials.

## Steps still to do (optional, not blocking)

10. Update OAuth app redirect URIs (GitHub/ORCID/Globus) to include
    `https://usermanagement.sandbox.brainkb.org/api/auth/<provider>/callback`, and fill
    in `NEXT_PUBLIC_JWT_USER`/`PASSWORD` with a real service account, if you want real
    login to work end-to-end (not done yet — current state proves the deployment
    pipeline works, not full feature parity).
