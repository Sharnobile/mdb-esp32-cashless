# App Store review — access & demo-account runbook

The reviewer runs the **real** app against a **real** server. Screenshots come
from fixtures; review does not. This is what has to be in place.

## The reviewer-facing notes
Live in `ios/fastlane/metadata/review_information/notes.txt` and are uploaded by
deliver. They explain: the pre-selected server, how to sign in, that account
deletion is testable, and that this is a B2B operator tool (heads off Guideline
4.2/4.3 "who is this for" questions). Keep the password **only** in ASC's demo
fields, never in the repo.

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
