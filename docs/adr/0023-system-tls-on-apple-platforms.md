# The core's WebDAV storage uses the operating system's TLS on Apple platforms

On Apple targets, ureq runs on `native-tls` (the Security framework) and checks certificates against the Device's trust store. A self-hoster (ADR-0017) whose server uses a certificate from their own CA can Connect once the Device trusts that CA; untrusted certificates are still refused and still reported as Unreachable. Connections stay HTTPS-only. rustls, ring and the bundled public root list leave Apple builds. Other platforms keep rustls until they choose their own TLS, and record it here or in a later ADR.

## Considered Options

- **rustls with the bundled roots (before)**: identical everywhere, but trusts only public CAs, so a private CA is impossible, and it adds binary size.
- **rustls with the platform verifier**: honors the trust store, but still ships rustls and ring.

## Consequences

- Release build of the macOS app executable, before → after: 7,406,424 → 6,676,808 bytes (−9.9%).
- ureq's `native-tls` feature also compiles in the `webpki-root-certs` data, though it is not used on Apple (the trust store is set explicitly): `native-tls-no-default` does not enable ureq's native-tls code.
- The default provider of ureq is rustls, so the Apple config sets the provider and root source explicitly (`tls_config` in `webdav.rs`).
- The Security framework refuses leaf certificates valid longer than 398 days and without the `serverAuth` extended key usage. The WebDAV tests generate a 30-day certificate with `openssl` and skip without it or `rclone`.
- Checked: a public HTTPS host passes the trust store (reaches "not a WebDAV server"); the tests' self-signed certificate is trusted only when passed as root, otherwise Unreachable.
- Not yet checked: a server with a certificate from a private CA installed in the Device's trust store. To check: serve WebDAV with `rclone serve webdav --cert --key`, trust the CA in Keychain Access (or install a profile on iOS), and Connect.
