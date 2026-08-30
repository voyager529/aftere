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
