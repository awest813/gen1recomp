# Signing in-place updates

A packaged desktop or handheld build updates itself in place: it downloads the
release's `gen1recomp-X.Y.Z.love` and starts it at the next launch
(`src/update/`). That payload is code the game runs, so it is taken only with
the project's signature:

- Each release signs `sha256sums.txt` with an ed25519 key and publishes the
  signature as `sha256sums.txt.sig`.
- The game checks that signature against the public key pinned in
  `src/update/Signing.lua` before it keeps a download. It checks it again, with
  the payload's checksum, at every start before it opens the file. A `.love`
  put in the save folder any other way is never run.
- Until a key is pinned, or for a release without a signature, the launcher
  offers the full package instead of updating in place.

## One-time setup

Make the key on a machine you trust, and keep the private key nowhere but the
repository secret:

```bash
openssl genpkey -algorithm ed25519 -out update-signing-key.pem
```

The public half, as the 64 hex digits the game pins:

```bash
openssl pkey -in update-signing-key.pem -pubout -outform DER | tail -c 32 | od -An -v -tx1 | tr -d ' \n'; echo
```

1. Put those 64 digits in `src/update/Signing.lua`:
   `Signing.PUBKEY = "<64 hex digits>"`, and commit it.
2. Add the whole PEM file as the repository secret `UPDATE_SIGNING_KEY`
   (Settings > Secrets and variables > Actions).
3. Delete the local copy, or keep it offline; anyone holding it can sign an
   update every installed copy will run.

The release workflow's "Sign the update checksums" step signs the list, checks
the signature's key against the one pinned in `Signing.lua`, and fails the
release when they differ. Without the secret it warns and publishes the release
unsigned.

## Changing the key

Installed copies accept only the key they pin. To move to a new key, publish
one release that pins the new key but is still signed with the old one:
existing copies accept it and so learn the new key. Sign every release after
that with the new key.

## If an update breaks

An update counts as good once it has run for 10 seconds or quit cleanly. One
that crashes or shows an error before that is set aside, and the next launch
starts the version that came with the app. `--skip-updates` (or
`POKEPORT_SKIP_UPDATES=1`) starts that version on purpose.
