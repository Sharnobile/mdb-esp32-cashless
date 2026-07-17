# Seed the App Store review demo org on PROD

Run before each App Store submission (the reviewer deletes the demo account per
Guideline 5.1.1(v); re-running restores it). Everything runs **on the Contabo
prod server**, where the Docker stack lives. Uses `scripts/seed-demo-org.sql`
(idempotent, confined to a fixed demo company id).

## 0. Prerequisites
- SSH access to the prod server, and the repo checked out there (the dir with
  `Docker/docker-compose.yml`).
- A **new** demo password. The old `applereview` was accidentally committed to
  the public repo — do not reuse it.

## 1. Create the demo login account (once, or after a reviewer deletes it)
GoTrue admin API, using the service-role key from `Docker/.env`. From the repo's
`Docker/` dir on the prod box:

```bash
export SERVICE_ROLE_KEY="$(grep -E '^SERVICE_ROLE_KEY=' .env | cut -d= -f2-)"

curl -s -X POST "https://supabase.kerl-handel.de/auth/v1/admin/users" \
  -H "apikey: $SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"review@kerl.io","password":"<NEW-STRONG-PASSWORD>","email_confirm":true}'
```

- `email_confirm:true` makes the account immediately usable (no confirmation mail).
- If it prints `email_exists` / 422, the account is already there — either reset
  its password in Supabase Studio, or delete it first (Studio → Authentication),
  then re-run this.

## 2. Seed the demo org
Pull the repo, then pipe the seed SQL into the db container. From the `Docker/`
dir:

```bash
git -C .. pull

docker compose exec -T db psql -v ON_ERROR_STOP=1 \
  -v admin_email='review@kerl.io' \
  -v second_admin_email='' \
  -U postgres -d postgres < ../scripts/seed-demo-org.sql
```

Expect: `NOTICE: Demo org seeded: company=… admin=review@kerl.io … machines=3 …`.

**Sole admin vs. two admins** — the `second_admin_email=''` above makes
`review@kerl.io` the **sole** admin. When the reviewer deletes that account, the
whole demo company is erased and the app asks them to type the company name
(`VMflow Demo GmbH`) to confirm — mention that name in the ASC review notes.
If you'd rather the reviewer get the simpler one-tap deletion (company survives),
create a second throwaway account (repeat step 1 with another email) and pass it
as `second_admin_email='review2@kerl.io'`.

## 3. Verify
```bash
docker compose exec -T db psql -U postgres -d postgres -c \
"SELECT name FROM companies WHERE id='00000000-de00-4000-a000-000000000001';
 SELECT count(*) AS machines FROM \"vendingMachine\" WHERE company='00000000-de00-4000-a000-000000000001';
 SELECT count(*) AS sales FROM sales s JOIN embeddeds e ON s.embedded_id=e.id
   WHERE e.company='00000000-de00-4000-a000-000000000001';"
```
Expect: `VMflow Demo GmbH`, `machines = 3`, `sales = 30`.

Then open the iOS app (or web) against prod, sign in as `review@kerl.io` with the
new password, and confirm Dashboard/Machines/Warehouse show data.

## 4. Put the credentials in App Store Connect
App Store Connect → your app → **App Review Information**:
- Demo account: `review@kerl.io` / the new password
- Phone in international format: `+49 151 62461076`
- Notes: paste the block from `docs/ios/app-store-review-notes.md`

These persist across versions — you only redo them if they change.

## Re-seeding later
Just re-run **step 2** (it wipes and rebuilds the demo company via the app's own
`delete_company_and_data`). Only redo **step 1** if the reviewer actually deleted
the auth account.
