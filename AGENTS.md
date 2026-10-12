# Agent instructions

## TestFlight build numbering

- Let the TestFlight release workflow auto-increment the build number. Do not set or override the build number manually.
- If a release issue appears to require a manual build-number override, stop and ask the user for confirmation before proceeding.
- Treat the marketing version (`CFBundleShortVersionString`) separately; change it only when the user requests a version change.
