# ULTRA@503 Material Traceability & Handover System — Phase 1

Standalone plain HTML/CSS/JS SPA backed by Supabase and deployed to GitHub Pages.

## Supabase setup
1. Create a Supabase project.
2. Open SQL Editor and run `supabase/001_schema.sql`, then `supabase/002_security_and_triggers.sql`.
3. Create a **private** Storage bucket named exactly `attachments`.
4. In Authentication settings, enable Email + Password. Create/invite employees.
5. Copy Project URL and anon/publishable key into `config.js`. Never use a service-role/secret key in frontend code.
6. Assign each employee's `profiles.role` manually in Table Editor after they sign in and create their profile.

## GitHub Pages
1. Create a new repository and upload all files in this folder.
2. Settings → Pages → Build and deployment → Source: **GitHub Actions**.
3. Push to `main`; workflow `.github/workflows/main.yml` deploys the site.

## Important
- The browser app is a Phase 1 scaffold and requires the SQL migrations to be applied first.
- Supabase RLS is the security boundary; do not weaken it to fix frontend errors.
- Scanner uses jsQR fallback. Camera access requires HTTPS (GitHub Pages is HTTPS).
- `special_process` can currently be completed by admin only.
- Storage upload UI and richer guided rework verification / dispatch planning are not yet implemented in this initial scaffold; tables/policies are included in SQL.
