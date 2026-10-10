# BG3 Party Planner

Builds, level plans and a shared gear checklist for a four-player Baldur's Gate 3 Honour Mode party.

Live site: https://ethranes.github.io/bg3partyplanner/

- `index.html` is the whole site: one static page, no build step. GitHub Pages serves it from the `main` branch root.
- Gear, locations and player names live in Supabase. Anyone with the link can view them; changing them needs the party passcode, which each device asks for once and remembers.
- `supabase/schema.sql` is the database setup and `supabase/seed.sql` the starting data. Both are already applied to the live project.

To change the passcode, run the snippet in `supabase/schema.sql` (search for "Set or change the passcode") in the Supabase SQL editor. Everyone then enters the new one the next time they edit.
