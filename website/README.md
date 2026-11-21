# VoiceType company pages

Public information for the existing VoiceType build 27 product:

- Product / marketing: https://apeonwheels.com/voicetype/
- Privacy policy: https://apeonwheels.com/voicetype/privacy/
- Support: https://apeonwheels.com/voicetype/support/

The pages contain no third-party scripts, analytics, cookies, web fonts, or
external images. They use the existing company domain and static web container.
Support includes English instructions and a Chinese help section.

## Source and rebuild

The privacy and support sources are `docs/PRIVACY_POLICY.md` and
`docs/SUPPORT.md`. The product page template is in `build_company_pages.py`;
styles are in `voicetype/site.css`. Run `python3 website/build_company_pages.py`
from the repository root (requires Pandoc) to rebuild the three HTML pages.

The policy follows the restored build 27 behavior. It does not claim the new
build 28/29 cloud-consent screen, consent withdrawal toggle, or offline typing
keyboard exists. It discloses OpenAI processing, account-linked history,
on-device failed recordings, per-account vocabulary hints, account deletion,
the welcome-credit anti-abuse marker, and restricted backup copies.

## Existing production host

GCP `voicetype-api`, project `voicetype-y-dog-20260604`, zone `us-central1-a`.
The `migration-static` container reads the company's static site from:

`/opt/migration-20260917/apps/source/root/apeonwheels_source`

Only the `voicetype/` subtree is replaced. The deployment script backs up the
entire company site and Caddy configuration first, validates a candidate Caddy
configuration, verifies all other company file hashes are unchanged, and checks
public response bytes against local files.

Caddy redirects legacy `/privacy`, `/privacy-policy`, `/support`, and `/help`
URLs on `voicetype.y.dog` to these company pages. This keeps links in existing
app binaries working without changing the app. The API and owner console stay
on `voicetype.y.dog`.

## Publication evidence, 2026-10-02

`build/company-pages-20261002/production-verification.json` records four HTTPS
200 responses, four working legacy redirects, and 14 unchanged unrelated files.
No container was restarted. The VoiceType health endpoint, company home page,
and existing Guanxiang and Money Flow privacy pages also returned 200.

Production backup:
`/opt/voicetype/backups/company-voicetype-20261002T093402Z` (before initial publication).
The final wording correction, covering automatic clip completion and operational
log retention, was verified at `20261002T102120Z`; its preceding snapshot is
`/opt/voicetype/backups/company-voicetype-20261002T102120Z`.

The product page was visually checked at the default desktop viewport; privacy
and support were checked at 390 × 844. Screenshots are in the same local evidence
directory. Temporary browser viewport settings were reset after inspection.
