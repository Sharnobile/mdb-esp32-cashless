# App Store review — access & demo-account runbook

The reviewer runs the **real** app against a **real** server. Screenshots come
from fixtures; review does not. This is what has to be in place.

## Review information is set BY HAND in App Store Connect — not via deliver
This repo is public, so the demo credentials and phone must never live in it.
deliver's review-info upload is one atomic POST (contact name, phone, demo
user/password, notes) — you cannot automate the notes without also committing the
secrets. So the whole **App Review Information** section is set once, by hand, in
App Store Connect (it persists across versions; deliver is configured to skip it).

Enter in App Store Connect → your app → App Review Information:
- **Sign-in required:** Yes
- **Demo account** — User: `review@kerl.io`, Password: *(the demo account
  password — NOT stored here)*
- **Contact** — First: Lucien, Last: Kerl, Email: info@kerl-handel.de
- **Phone:** in international format, e.g. `+49 151 62461076` (ASC rejects the
  local `0151…` form)
- **Notes:** paste the block below.

```
VMflow is a business tool for operators of vending machines. It connects to a self-hosted backend and requires an account.

SIGNING IN
The demo account above is already tied to a demo organisation with seeded machines, sales and stock. On the sign-in screen, the correct server (supabase.kerl-handel.de) is pre-selected — no action is needed there. Just enter the demo credentials and tap Sign In.

WHAT YOU CAN TEST
- Dashboard, machines, trays/stock, the guided refill tour, and warehouse are all populated with demo data.
- Account deletion (Guideline 5.1.1(v)) is available in Settings → Delete Account, and also on the "No organization" screen shown right after registering a fresh account. The demo account is disposable and re-seeded before each submission, so deleting it is safe to test.

ABOUT THE SERVER PICKER
VMflow can connect to different self-hosted servers (operators run their own). The picker on the sign-in screen exists for that reason; the demo server is pre-selected, so you can ignore it.

This app is intended for commercial vending operators managing their own business data; it is not a consumer social or content app.
```

> ⚠️ **The demo password `applereview` was accidentally committed to this public
> repo and pushed. Treat it as compromised: change the demo account's password
> in Supabase and set the new one only in App Store Connect.**

## The demo account — must be disposable
Guideline 5.1.1(v) means the reviewer will likely **delete** the demo account.
If that account is your only demo, the next review has nothing to sign into.

So the demo org on `supabase.kerl-handel.de` must be **re-seedable**:
- A demo company with a handful of machines, products, sales and stock — enough
  that Dashboard/Machines/Refill/Warehouse all look populated.
- A demo user (admin) whose credentials go in ASC's demo fields.
- A way to re-create both before each submission (a small seed script or a saved
  SQL snapshot). Assume the account gets destroyed every review cycle.

Consider **two** demo users in the demo org (so one can delete their account
without orphaning the company — the sole-admin path erases the whole company,
which you'd then have to re-seed anyway; with a second admin the reviewer
exercises the ordinary deletion path and the org survives).

## Checklist before hitting Submit
- [ ] Demo org + data seeded on supabase.kerl-handel.de
- [ ] Demo credentials entered in ASC (or `review_information/*.txt` + `deliver`)
- [ ] `phone_number.txt` filled
- [ ] Verified you can sign in with those exact credentials on a clean install
- [ ] Server picker shows the demo server pre-selected
- [ ] Account deletion works end-to-end with that account
