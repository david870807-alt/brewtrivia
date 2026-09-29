# BrewTrivia — deploy in about 20 minutes

No build step, no server to run. Two services, both free to start:

| Service | What it does | Cost |
|---|---|---|
| **Supabase** | Database, sign-in (guest / Google / Apple / email), live leaderboard | Free up to 50k users |
| **Netlify** (or Vercel / Cloudflare Pages) | Hosts the 6 static files on brewtrivia.com | Free |

Only `config.js` is edited. Everything else is copied as-is.

---

## 1. Supabase (10 min)

1. Go to **supabase.com** → New project → name it *brewtrivia*, region **East US** (or West US if you start in California). Save the database password somewhere.
2. Left menu → **SQL Editor** → New query → paste the whole of `supabase/schema.sql` → **Run**. It should finish with "Success".
3. **Project Settings → API**: copy **Project URL** and the **publishable** (or `anon`) key into `config.js`.

No auth toggles are needed: guests play with a device token (zero email quota), and signing in later moves their points to the account automatically.

Test it right now: open `index.html` on your computer, type a name, tap *Start playing*. If you see *Find trivia* with "No venues yet", the database works.

## 2. Google sign-in (10 min, needed for venues)

Players can be guests. **Listing a venue requires a real account**, so at least Google should be on.

1. **console.cloud.google.com** → APIs & Services → Credentials → Create credentials → **OAuth client ID** → Web application.
2. Authorized redirect URI: `https://<your-project-ref>.supabase.co/auth/v1/callback` (Supabase shows this exact line on the Google provider page).
3. Copy Client ID + Client secret into Supabase → Authentication → Providers → **Google** → Save.

**Apple**: same page, needs an Apple Developer account ($99/yr) and a Services ID. Do it before App Store-style polish, not before the first pilot.

**Email links**: Supabase's built-in mailer only sends to your own team's addresses. To send to the public, add custom SMTP (Project Settings → Auth → SMTP) — Resend or Postmark, ~$0–20/mo. Until then, guest + Google covers everyone.

## 3. Put it online (5 min)

1. **netlify.com** → sign up → *Add new site → Deploy manually* → drag the whole `brewtrivia` folder onto the page.
2. You get `something.netlify.app`. Open it on your phone — geolocation and *Add to Home Screen* work now.
3. Custom domain: Netlify → Domain management → add `brewtrivia.com` → point the DNS records it shows you (at Cloudflare, or wherever you buy the domain).
4. Back in Supabase → **Authentication → URL Configuration**:
   - Site URL: `https://brewtrivia.com`
   - Redirect URLs: add `https://brewtrivia.com/**` and your `*.netlify.app/**`

Redeploy = drag the folder again. That's the whole release process.

## 4. First venue

On your phone: *Me → List your venue* → sign in with Google → fill in the venue → write questions. Print the join code with a QR pointing to `https://brewtrivia.com` and put it on the tables.

---

## What's inside

| File | Purpose |
|---|---|
| `index.html` | The whole app — player flow, host dashboard, question editor |
| `config.js` | Your Supabase URL + key (the only file you edit) |
| `supabase/schema.sql` | Tables, security rules, `ranking()` and `venue_board()` functions, realtime |
| `manifest.webmanifest`, `sw.js`, `icon.svg` | Makes it installable on iOS/Android home screens |

Replace `icon.svg` with a 512×512 PNG named the same way if you want a crisper iOS home-screen icon.

## Security model

- Anyone can read venues, questions and scores (it's a public leaderboard game).
- A player can only insert their **own** score (accounts via auth, guests via a secret device token sent as a header).
- A venue can only be edited by its owner; a guest account can't create one.
- Scores are computed on the phone in this version. Before running for cash prizes, move grading into a database function (`submit_answers`) so the correct answers never reach the browser — about 40 lines of SQL, no UI change.

## Later

- **SEO pages per venue** ("trivia tonight in Fishtown") → move the frontend to Next.js on Vercel. The database and auth stay exactly as they are.
- **Stripe** for venue plans, **Resend** for reminder emails, **PostHog** for analytics — all plug into this same Supabase project.
