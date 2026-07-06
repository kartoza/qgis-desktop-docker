# Scenarios

Worked-example deployments that combine several of the knobs from
[Configuration](../configuration/index.md) into a runnable end-to-end
setup.

- **[Analyst locked-down session](analyst-locked-down.md)** — single
  analyst account, clipboard blocked in both directions, screen
  watermarked, and egress restricted to a co-located PostGIS container.
  Ships with UML diagrams, a `docker-compose.yml`, and a verification
  checklist. Try it with `nix run .#run-analyst-scenario`.

Each scenario page describes the requirements, the topology, the
container internals, the compose file, how to run it, and a checklist for
confirming every requirement is enforced.
