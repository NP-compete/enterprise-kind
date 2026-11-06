# keycloak-realm.json

Keycloak's realm parser rejects unknown top-level keys, so the file itself
carries no comments. Two omissions in it are deliberate and easy to "fix" back
into a broken state:

**No `clientScopes` key.** Declaring one *replaces* Keycloak's built-in scopes
(`profile`, `email`, `roles`, `web-origins`, `basic`, `acr`) rather than adding
to them. The realm then has only your custom scopes, every client requesting
`profile email` is rejected with `invalid_request: Invalid scopes`, no
authorization code is issued, and the app reports the confusing downstream
error `invalid_grant: Code not valid`.

**No per-client `defaultClientScopes`.** Clients and scopes are created in the
same import pass, so an explicit list can be applied before the built-in scopes
exist — Keycloak logs `Referenced client scope 'profile' doesn't exist.
Ignoring` and the client silently ends up with a partial scope set. Omitting
the key lets clients inherit the realm defaults instead.

The custom `groups` scope (and its group-membership protocol mapper) is
therefore created *after* import, over the admin API, by
`scripts/keycloak-reconcile.sh`. That script is idempotent and also re-attaches
any missing default scope to the four platform clients, so it fixes drift
whether it was caused by import ordering or by someone clicking in the console.

## Changing the realm

`--import-realm` only runs at container startup, and only for realms that do
not already exist. Two consequences:

- Editing this file alone does nothing to a running Keycloak. The Keycloak pod
  carries a `platform.kind.local/realm-checksum` annotation derived from the
  rendered file, so `make install` rolls the pod automatically when it changes.
- A roll still will not *update* an existing realm. To genuinely re-import,
  delete the realm first (Keycloak admin console → realm settings → delete, or
  the admin API), then run `make install`.
