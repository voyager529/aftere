# after/e/ — QA run bundle

Snapshot of the current script iterations for a fresh-VM QA deployment.

## Layout (keep this flat; scripts find each other + docker-compose.yml by walking up)
```
docker-compose.yml        the stack (worker env now includes blueprint !Env vars)
common.sh                 shared lib: base-path, hostnames, helpers, preflight, readiness
prereqs.sh                installs docker/cron/git/socat/dig/swaks/jq/envsubst
dns-setup.sh              shows required DNS records, loops until A+MX resolve
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
