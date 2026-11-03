# Security

Stay Awake is experimental. Automated tests do not certify security or prove
unattended operation. Basic signed-service installation and a brief closed-lid
session were exercised on one Mac. Recovery after crashes, real hotspot handoff
and full uninstall still require supervised integration checks. Do not use unattended sessions yet.

The local power service accepts a fixed set of operations. Both peers require
the same application identifier and Team ID. Distribution builds require a
Developer ID Application certificate. The compile-time local-source channel
requires Apple Development, Hardened Runtime, no entitlements, an exact cdhash
on both peers, and a root-owned app tree with protected ancestors. A different
build signed with the same local key is rejected.
Power changes are journaled before application, checked after restoration, and
bounded by a deadline and independent battery/thermal safeguards. Permanent UI
sessions use renewable leases, not an infinite privileged grant.

The local installer does not add sudoers rules or disable Gatekeeper or SIP.
Developer ID/notarization checks do not replace a code review. Do not share
passwords, signing keys, Keychain items, Wi-Fi names or personal logs in public.
See LOCAL-SOURCE-INSTALL.md, LOCAL-README.md and VALIDATION.md for current limits and recovery behavior.
