# Scenarios

Worked deployments that combine the knobs from
[Configuration](../configuration/index.md) into something runnable. Every one
has a compose file in
[`examples/`](https://github.com/kartoza/qgis-desktop-docker/tree/main/examples)
and a `nix run` target, so you can have it in front of you in one command.

## Object storage — persistent homes

The container is disposable; the home directory is not. These four cover the
storage layer from every angle.

| Scenario | What it demonstrates | Run it |
|----------|----------------------|--------|
| **[Persistent workstation](persistent-workstation.md)** | The basics: a home directory in a bucket, restored at boot, saved continuously, with a provisioned project | `nix run .#run-persistence-demo` |
| **[Delivering data](team-data-drop.md)** | Getting files to a user without touching their container — `provision/` for a baseline, `inbox/` for a hand-off | `nix run .#run-data-drop-scenario` |
| **[The disposable desktop](disposable-pod.md)** | Deliberately breaking it: hard kills, recreated pods, two containers on one prefix, a wiped home, a blown quota | `nix run .#run-disposable-scenario` |
| **[SSO + persistent homes](sso-persistent-homes.md)** | Storage and identity composed — the production shape | `nix run .#run-sso-homes-scenario` |

## Keycloak and single sign-on

Nobody has an account inside the container. Access is decided before the request
reaches the desktop.

| Scenario | What it demonstrates | Run it |
|----------|----------------------|--------|
| **[Keycloak SSO](keycloak-sso.md)** | An OIDC proxy in front of the desktop, role-gated, with a user who is deliberately refused | `nix run .#run-keycloak-demo` |
| **[Using your own Keycloak](keycloak-byo.md)** | You already run Keycloak and have admin: the nine steps to wire a container to it, console and `kcadm.sh`, with a preflight check | `nix run .#check-oidc` |
| **[Federating an IdP](federated-idp.md)** | Keycloak as a *broker* in front of Entra ID / Google / Okta / LDAP, turning an existing group into entitlement | `nix run .#run-federated-idp-scenario` |
| **[SSO + persistent homes](sso-persistent-homes.md)** | Identity in Keycloak, state in a bucket, nothing durable in between | `nix run .#run-sso-homes-scenario` |
| **[Multi-user greeter](multi-user-greeter.md)** | A per-user Linux session inside the container, on its own or behind SSO | `nix run .#run-greeter-scenario` |

## Restricting what the session can do

| Scenario | What it demonstrates | Run it |
|----------|----------------------|--------|
| **[Analyst locked-down](analyst-locked-down.md)** | Clipboard blocked, watermarked, no terminal, egress restricted to a co-located PostGIS | `nix run .#run-analyst-scenario` |
| **[Kiosk display](kiosk.md)** | QGIS on a screen someone walks up to: autostarted on a project, no terminal, no clipboard, no network | `nix run .#run-kiosk-scenario` |

## Picking one

- **Giving one person a desktop they come back to?**
  [Persistent workstation](persistent-workstation.md).
- **Already run Keycloak and just need this wired to it?** [Using your own
  Keycloak](keycloak-byo.md) — start there, not with the demos.
- **Rolling it out to a team with an existing directory?**
  [Federating an IdP](federated-idp.md), then add persistence.
- **About to run this on Kubernetes?** [The disposable
  desktop](disposable-pod.md), before anything else.
- **Need to get a dataset to someone mid-session?** [Delivering
  data](team-data-drop.md).
- **Handing a contractor a session over data you care about?**
  [Analyst locked-down](analyst-locked-down.md).
- **Putting a map on a screen in a public place?** [Kiosk display](kiosk.md).

Each page describes what the scenario enforces, how it is wired, how to run it,
and a checklist for confirming every requirement actually holds — including the
things it deliberately does *not* protect against.
