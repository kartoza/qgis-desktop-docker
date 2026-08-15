# Scenarios

Worked-example deployments that combine several of the knobs from
[Configuration](../configuration/index.md) into a runnable end-to-end
setup.

- **[Analyst locked-down session](analyst-locked-down.md)** — single
  analyst account, clipboard blocked in both directions, screen
  watermarked, and egress restricted to a co-located PostGIS container.
  Ships with UML diagrams, a `docker-compose.yml`, and a verification
  checklist. Try it with `nix run .#run-analyst-scenario`.

- **[Multi-user greeter session](multi-user-greeter.md)** — shared
  workstation with a LightDM login form inside the desktop, per-user
  homes, and clean log-out → re-prompt without closing the browser.
  Try it with `nix run .#run-greeter-multi`.

- **[Keycloak single sign-on](keycloak-sso.md)** — no user accounts in
  the container at all: an OIDC proxy authenticates against your identity
  provider and admits only users holding the right role. Ships with a
  throwaway Keycloak realm. Try it with `nix run .#run-keycloak-demo`.

Each scenario page describes the requirements, the topology, the
container internals, the compose file, how to run it, and a checklist for
confirming every requirement is enforced.
