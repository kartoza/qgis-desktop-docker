<!--
SPDX-FileCopyrightText: Kartoza
SPDX-License-Identifier: GPL-2.0-or-later
-->

# secrets/

Two files, neither committed:

```bash
# from Keycloak: Clients -> qgis-desktop -> Credentials -> Client secret
printf '%s' 'your-client-secret' > oidc-client-secret

# any 32 bytes; without a stable value every restart signs everybody out
head -c 32 /dev/urandom | base64 | tr -d '=\n' | tr -- '+/' '-_' > oidc-cookie-secret

chmod 400 oidc-client-secret oidc-cookie-secret
```

The container reads both as root and scrubs them from the environment before
the unprivileged desktop session starts, so the signed-in user cannot read
either one.
