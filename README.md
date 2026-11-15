# AUSSNSC — app + server, shipped by one command

```
you ──► Termux: bash ~/ship.sh ──► GitHub repo ──┬─► Actions "Build APK"  ──► Release v<N> (APK) ──► Termux downloads it
        (tar in Downloads)                       ├─► Actions "Backend tests" (quality check)
                                                 └─► Render redeploys the server automatically
```

Versions are the number in the tar name: `AUSSNSC.tar4.gz` → app **v4**, `AUSSNSC.tar5.gz` → app **v5** …
The number must go up every time (Android only installs newer builds over older ones).

## Every new version (the only thing you do)

1. Save the new tar in **Downloads**, named `AUSSNSC.tar<number>.gz` (e.g. `AUSSNSC.tar5.gz`).
2. In Termux:
   ```bash
   bash ~/ship.sh
   ```
   It unpacks the newest tar, uploads to GitHub, waits for the build (5–8 min), downloads
   `AUSSNSC-v5.apk` into Downloads and opens the installer. If the build fails, it saves
   `aussnsc-build-error.txt` in Downloads — send me that file.

Other forms: `bash ~/ship.sh path/to/tar` · `--force` (re-ship the same number) · `--download-only` (just fetch the newest APK).
You can also download any APK from your repo on GitHub: **Releases → v5** (or **apk-latest**).
A tar with only a few files (a patch) also works; it just overwrites those files. A full tar replaces everything
(files you deleted disappear). Your Firebase file and server address are never overwritten.

---

## One-time setup

### 1 · Firebase (Google login) — browser, ~10 min
1. https://console.firebase.google.com → **Add project**.
2. **Build → Authentication → Get started → Sign-in method → Google → Enable** (choose a support email, Save).
3. **Project settings → Your apps → Android**: package name `com.aussnsc.app`, **SHA-1**
   `EA:50:FE:0D:5F:9F:2D:68:02:C8:48:66:AB:2C:DB:53:90:D4:01:39` → Register → **download `google-services.json`**
   into your phone's **Downloads** (re-download it if you added the SHA-1 afterwards).
4. Copy the **Project ID** (needed for Render).

### 2 · Termux first run
```bash
pkg install -y tar git gh curl
termux-setup-storage                                   # tap Allow
tar xzf ~/storage/downloads/AUSSNSC.tar4.gz AUSSNSC/termux/ship.sh -O > ~/ship.sh
bash ~/ship.sh
```
It asks you to log in to GitHub (a code appears; enter it at github.com/login/device), creates a **private** repo,
stores `google-services.json` as a secret, uploads, builds, and downloads the APK.
When it asks for the Render URL, press Enter (you don't have one yet).

### 3 · Render (the server)
1. https://dashboard.render.com → **New → Blueprint** → connect GitHub → pick the repo.
2. Fill the 3 questions: `ADMIN_PHONE` (your admin login), `ADMIN_PASSWORD` (strong), `FIREBASE_PROJECT_ID` (from step 1.4) → **Apply**.
3. Open `https://YOUR-SERVICE.onrender.com/health` → should show `{"status":"ok"}`. Copy that address.

### 4 · Point the app at the server (once)
```bash
bash ~/ship.sh --server https://YOUR-SERVICE.onrender.com --force
```
The address is remembered (stored in `android/api.properties` in the repo); future tars never reset it.

---

## First use as admin
1. Open the app → **Sign in** with `ADMIN_PHONE` + `ADMIN_PASSWORD`. Admin tools: dashboard, users, parent links, admission applications, post notice.
2. Classes 6–10 (A/B) and their chat channels already exist.
3. Adding students, teachers, results, routines, gallery, school info happens in the server's admin page
   `https://YOUR-SERVICE.onrender.com/docs`: run **POST /api/v1/auth/login** → copy `access_token` → **Authorize** → use the
   `/admin/...` endpoints (`POST /admin/students`, `/admin/students/import` CSV, `/admin/teachers`, `/admin/results/import` + `/admin/results/publish`,
   `PUT /admin/routines/class/{id}`, `PUT /admin/content/about`, …). Tokens last 60 min.
4. New people register in the app (or Google) → **public** account. In the app: **Users → tap → Make student/parent/teacher**.
   Students need a record: `POST /admin/students` with their `user_id`. Teachers: `POST /admin/teachers` with `user_id`, then
   `POST /admin/teachers/{id}/classes`. Parents send *Link a child* → you approve under **Pending Parent Links**.

---

## Good to know (honest list)
- **First build is the real test.** The sandbox I work in can't compile Kotlin or run the server, so I check code by reading it.
  If a build fails, send me `aussnsc-build-error.txt`; fixes are usually one line.
- **"Backend tests"** is a separate check in GitHub Actions (red ✗ on a commit = a server test failed). It never blocks the APK.
- **Render free plan:** server sleeps after ~15 min idle (first request ~1 min). Check Render's current free-database limits before using real
  school data. Files uploaded to the server are lost on restart on the free plan — the app doesn't upload files yet.
- **SMS/email OTP are placeholders** (codes only appear in Render logs). Sign-in uses password or Google, so nothing depends on them.
- **Not included yet:** push notifications in the app, Bangla translation of screens (the language choice is saved), file attachments.
- **Android:** 6.0+ (including Android 7). The APK is signed with the fixed key in `android/app/debug.keystore`: fine for installing directly, not for Google Play.
- Name-based result search is public by design (limited and rate-limited) — think about student privacy before using real data.

## Troubleshooting
| Symptom | Fix |
|---|---|
| `No AUSSNSC.tar<number>.gz found` | Save the tar in Downloads with exactly that name pattern. |
| `tar5 is not newer than … v5` | Use a higher number, or add `--force`. |
| Build failed | Send me `Downloads/aussnsc-build-error.txt` (or open GitHub → Actions → the red run). |
| "App not installed" | The new APK must have a higher number than the installed one (v4 → v5). |
| "Can't reach the server" | Free server waking up — wait a minute. Check the Render URL with `--server … --force`. |
| Google button: "isn't set up in this build" | `google-services.json` wasn't in Downloads when you shipped. Put it there and run `bash ~/ship.sh --force`. |
| Google error 10 / developer error | SHA-1 missing in Firebase (step 1.3), or re-download `google-services.json` after adding it. |
| "Google sign-in could not be verified" | `FIREBASE_PROJECT_ID` on Render must equal the Firebase Project ID exactly. |
| Lost admin password | Render → service → Environment: set `ADMIN_PASSWORD` and add `RESET_ADMIN=1`, save, sign in, then delete `RESET_ADMIN`. |
