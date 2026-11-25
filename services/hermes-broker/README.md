# hermes-broker

The only door to root for the Hermes agent. The agent has no privilege: it can
only **ask**, and the broker executes only what a human proof authorized.

## Why

`nixos-rebuild` is already scoped NOPASSWD, but everything else (restarting a
unit, reading a root file, repairing a path) forced asking for a password in the
chat. The broker replaces that typing with a choice of proofs, without widening
the agent's rights by an inch.

## Flow

1. The agent (user `hermes`) writes `{argv, cwd, reason}` to
   `/run/hermes-broker/broker.sock`. The kernel attributes the call to its uid
   through `SO_PEERCRED`, so there is no secret to steal on the agent side.
2. The broker (root) returns a single-use token valid for `BROKER_TTL` (300 s)
   and publishes the exact command on
   `https://broker.marcpartensky.com/r/<token>`.
3. Marc proves his identity through whichever channel he wants: system password
   (PAM) or WebAuthn passkey (Touch ID on the Mac, phone fingerprint,
   Bitwarden, hardware key). All channels are armed at the same time and the
   **first** valid proof consumes the request.
4. The broker executes the command as root, logs the call into
   `/var/lib/hermes-broker/audit.jsonl`, and returns stdout/stderr/rc to the
   agent.

## Agent-side usage

```
hermes-request --reason "restart nginx after a vhost change" -- \
  systemctl restart nginx
```

The client prints the approval URL on stderr as soon as the request is pending,
then the command's output.

## Enrolling a passkey

```
https://broker.marcpartensky.com/enroll
```

The system password authorizes the enrollment (once), then
`navigator.credentials.create()` registers the passkey. Verification requires
the `user-verification` flag, hence a biometric gesture or a PIN on every
assertion. Several passkeys can coexist (Mac, phone, Bitwarden); `creds.json`
holds only **public** keys.

## State

- `/var/lib/hermes-broker/creds.json`: registered passkeys (public keys)
- `/var/lib/hermes-broker/audit.jsonl`: one line per approval, refusal,
  expiration and execution
- log: `journalctl -u hermes-broker`

## What was abandoned

A home-made binary using a Secure Enclave key with the `biometryCurrentSet` ACL
would have given a native Touch ID dialog without a browser. macOS refuses: it
needs the `keychain-access-groups` entitlement, which requires an Apple
Developer identity. With an ad-hoc signature, adding the key fails with
`-34018` (missing entitlement), and setting the entitlement on an ad-hoc binary
gets the process killed by the kernel (SIGKILL). WebAuthn in Chrome, signed by
Apple, gives the same hardware key without a certificate; the price is that the
approval page has to be open.

## Tests

`python3 test_broker.py` (outside NixOS, in the source folder) verifies the full
cycle without hardware: page, WebAuthn options, ES256 verification, refusal of a
tampered signature, wrong rpId, missing user verification, expiration, real
execution and audit.
