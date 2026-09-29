# after-e- — QA run bundle

Snapshot of the current script iterations for a fresh-VM QA deployment.

## Layout (keep this flat; scripts find each other + docker-compose.yml by walking up)
```
docker-compose.yml        the stack (worker env now includes blueprint !Env vars)
common.sh                 shared lib: base-path, hostnames, helpers, preflight, readiness
prereqs.sh                installs docker/cron/git/socat/dig/swaks/jq/envsubst
dns-setup.sh              shows required DNS records (apex+mail A, rest CNAME), writes
                          a paste-ready zone snippet, loops until they resolve
cert-http.sh              acme.sh HTTP-01, one cert per hostname, STAGING default
init.sh                   the installer (draft 3)
new-user.sh               provision a user in Authentik (after deploy)
stalwart-provision.sh     v0.16 provisioning SCAFFOLD (needs a captured plan — see its header)
blueprints/*.yaml         Authentik OIDC apps + LDAP outpost (rendered by init.sh)
ARCHITECTURE.md           design rationale (reference, not runtime)
.env.example              reference only — init.sh generates the real .env
```

## Run order
```
sudo bash prereqs.sh        # once, installs host tooling
sudo bash init.sh           # the questionnaire + bring-up (calls dns-setup + cert-http)
# after it finishes and containers are healthy:
sudo bash new-user.sh       # create a test user to exercise the identity layer
```
`init.sh` defaults to STAGING certs (browsers will warn — expected). Once the run
is clean end-to-end: `sudo STAGING=0 bash cert-http.sh` for real certs.

## Before you run — external prerequisites (no script can do these)
- DNS A records for the serving domain's hostnames must point at THIS VM's IP.
- Firewall open on :80 and :443 (and mail ports if the mail tier is on).
- Save the generated `.env` OFF this box after the run — it holds every secret.

## What works this pass vs. what's stubbed
WORKS: full questionnaire (staging/prod split, Authentik admin you choose, Immich
privacy toggles, break-glass choice, progress bar), image preflight, DNS gate,
HTTP-01 certs, nginx vhosts, blueprint apply, and a reachable HTTPS surface where
you can log into Authentik and provision users.

STUBBED / NEXT: Stalwart provisioning (needs the one-time WebUI capture ->
`stalwart-cli snapshot` -> templated plan), postinstall (app-side OIDC/LDAP +
credential summary), and the Cloudflare/BYO cert modes.

## Two questions this run should answer
1. Does `aftere-authentik-ldap` reach (healthy)?  -> if yes, the injected outpost
   token worked; if it stays (unhealthy), use the read-back fallback in
   blueprints/20-ldap.yaml's header.
2. Does a `new-user.sh` account log in at https://auth.<serving-domain> and see
   the application launcher?  -> confirms the identity layer end to end.

Report those two and we'll know whether the identity fabric is truly wired
before sinking time into the Stalwart capture.


## Build 19 — what to test

Two changes, both unproven on a box.

### DNS record model (apex + mail = A, everything else = CNAME)
- Create only two A records (`@`, `mail`) and CNAME the rest to the apex. The
  gate should pass and report `CNAME host -> domain -> ip` for the CNAMEd ones.
- Deliberately CNAME the apex (or `mail.`) and confirm the gate BLOCKS with the
  explanation, instead of passing because the address still resolves.
- Check `$AFTERE_CONFIG/dns/zone.txt`. `ZONE=1 bash dns-setup.sh` prints it inline.
  It is an import snippet, not a loadable zone (no SOA/NS) — that is deliberate.
- PTR stays advisory and never blocks; on a pass it repeats once at the end.
- DKIM is deliberately absent from the zone snippet — Stalwart is the source.

### Dockhand (optional, profile `dockhand`)
- **VERIFY AT QA:** every endpoint in the bootstrap comes from the contributor's
  PoC against `:latest`. Nothing here has been exercised. Confirm the payload
  shapes, then pin `DOCKHAND_IMAGE` in `.env` to a real tag.
- Answer "no" to Q20 and confirm the second question is skipped, `COMPOSE_PROFILES`
  gains nothing, and no container starts.
- Answer "yes" + tunnel: `ss -tlnp | grep 3000` must show `127.0.0.1:3000` and
  nothing on the public interface. No `dockhand.` DNS record should be demanded.
- Answer "yes" + vhost: `dockhand.$DOMAIN` appears in the DNS gate and in
  `certs/domains.list`, and the vhost is written only AFTER the bootstrap passes.
- Fail-closed check: break a bootstrap step on purpose (e.g. point `DH` at a dead
  port) and confirm the container is stopped, no vhost is written, and the rest
  of the run continues.
- Confirm the printed admin password actually logs in, and that an unauthenticated
  `curl http://127.0.0.1:3000/api/environments` is refused.


## Build 19b — fixes from the 0829 run

All five are regressions or latent bugs found on a real box, not new features.

1. **`render_vhost` filename bug (latent since build 18).** In a single
   `local host="$1" ... conf=".../$host.conf"`, bash expands every right-hand
   side BEFORE assigning, so `$host` resolved to the CALLER's `host`. The main
   vhost loop is `while read -r host`, so inside it the global happened to be
   correct and filenames worked by luck; the first out-of-loop caller (the
   deferred dockhand vhost) wrote a file literally named `.conf` while its
   `server_name` was correct. Split into two `local` statements, plus a guard
   that refuses an empty hostname.
   - Test: fresh install with Dockhand + vhost. Expect
     `conf.d/dockhand.$DOMAIN.conf` and NO `.conf` dotfile.
2. **Stalwart data ownership.** `$DATA_PATH/stalwart` was root-owned; Stalwart
   runs as uid 2000 and crash-looped on `RocksDb ... /LOG: Permission denied`.
   Now chowned alongside the existing Authentik media chown. Certs get group
   read (chgrp 2000 + g+rX) rather than a chown, so cert-http's root-owned
   renewal does not re-break TLS in 90 days.
   - Test: fresh box, Stalwart reaches Up (not Restarting) with no manual chown.
   - VERIFY: `docker compose exec stalwart id` — 2000 is captured from the
     config.json ownership, not from the image's USER directive.
3. **Summary block reads `.env`, not `answers.env`.** `answers.env` is deleted
   before the summary runs, so `answer_get` printed sed errors and a blank
   Dockhand password, and the vhost/tunnel branch always took the tunnel path.
   - Test: install with the vhost option; expect a real password and the
     `https://dockhand.$DOMAIN` line, not tunnel instructions.
4. **Dockhand image hardcoded** to `fnsys/dockhand:latest`. `preflight_images`
   greps raw text and cannot expand `${DOCKHAND_IMAGE:-...}`, which printed a
   spurious "unverified (invalid reference format)".
   - Test: preflight lists `fnsys/dockhand:latest` as ok, no unverified lines.
5. **nginx `default_server` catch-all (`00-default.conf`)**, returning 444 for
   any unmatched Host, with a self-signed cert at `certs/_default/`. Previously
   an unmatched hostname was served by the first-loaded vhost — alphabetically
   `auth.` — so a missing vhost looked like an unexpected redirect to SSO.
   ACME challenges are still served on the catch-all so a first issue for a
   host with no vhost yet cannot 444 its own challenge.
   - Test: `curl -sI https://<nonexistent>.$DOMAIN` closes with no response;
     every real host still resolves; `cert-http.sh` still issues for a new host.


## Build 20 — what to test

### Install paths (now siblings of the checkout)
- Clone to /opt/aftere; defaults should be /opt/aftere-{config,data,logs}.
- "use /mnt/aftere" still gives the old layout.
- Change a path to something that DOESN'T EXIST -> hard retry, no mkdir. This is
  the important one: creating it would put data on the root disk and let a later
  mount hide it.
- Change a path to a read-only mount -> hard retry.
- Change a path to a plain local dir that exists -> warning only, proceeds.
- Free-space advisory prints for the data path either way; under 20G warns.

### Timezone
- Detected value offered as a starting point (cloud images are UTC).
- "America/New York" -> accepted, echoes America/New_York.
- "america/new_york" -> accepted, echoes corrected case.
- "Mars/Olympus" -> rejected with the Wikipedia pointer, re-prompts.
- .env TZ reflects the choice; containers show local time.

### Logs + rotation
- nginx logs at $AFTERE_LOGS/nginx, NOT under config.
- CrowdSec's read-only mount points at the same place — confirm it still fires
  after a rotation (`logrotate -f /etc/logrotate.d/aftere`). A rotation that
  silently blinds CrowdSec looks exactly like nothing being wrong.
- `docker inspect` shows json-file max-size 10m / max-file 5 on every service.
- `bash log-retention.sh 30 250M` rewrites the drop-in; bad args are rejected.

### Certs (the 0829 trap)
- `./cert-http.sh --STAGING=0` now FAILS with "unknown argument" instead of
  silently running staging.
- `--production` with staging certs on disk auto-forces reissue instead of
  "Domains not changed. Skipping."
- `--help` works; `--force` still available manually.

### Mail DNS moved
- dns-setup gates only A/CNAME (incl. mail. as a cert prerequisite) — a
  Nextcloud-only install is never blocked on MX/SPF/PTR.
- MX/SPF/PTR now verified at the END of stalwart-provision.sh, with a re-check
  loop. Ctrl+C leaves a provisioned Stalwart — nothing to unwind.
- SPF tiers: absent = hard fail; 2+ records = hard fail (RFC 7208 permerror);
  present-but-unexpected = advisory only (gateways/SES are valid setups).

### Immich (all captured from the 0829 box)
- Blueprint now sets `grant_types: [authorization_code]`. WITHOUT IT the flow
  dies with "Invalid grant_type for provider" and a vague browser error.
  Confirm the checkbox is ticked in Authentik's provider UI after apply.
- `immich-provision.sh` re-locks, regenerates the maintenance token (4h life),
  prints the handoff, takes an API key, PUTs system-config, enables OAuth.
- Refuses to run against a STAGING cert on auth.$DOMAIN — that was the real
  cause of "Unable to login with OAuth".
- Confirm: hal auto-registers as non-admin, storageLabel = Authentik username,
  admin created with the same email as SSO merges into ONE account.
- Password login deliberately left ON as break-glass.
- Map / release-check questions are GONE from init.sh — Immich's own wizard
  asks them.
