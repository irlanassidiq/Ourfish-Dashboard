# Fish Forever catch dashboard — Indonesia

A self-hosted version of the dashboard built from Rare's Fish Forever catch data
(data.rare.org). It is plain HTML: open `index.html` in a browser, or publish the
folder on any web host.

```
index.html                     the dashboard
d3.min.js                      charting library (d3 v7.9.0), included so it works offline
data.js                        the aggregated data the dashboard reads
build_data.R                   downloads the latest data and rebuilds data.js
.github/workflows/refresh.yml  GitHub: refreshes the data every night and publishes the site
```

`data.js` holds totals only (per month, day, place, buying unit and gear), plus
fish counts per length class and trip counts. No fisher or buyer names or IDs are
written, so it is safe to publish. Your API key is never written to any file here.

## Option A — GitHub Pages, updated automatically every night (free)

1. Create a new **public** repository on GitHub (Pages on private repositories needs a paid plan).
2. Upload everything in this folder, including the hidden `.github` folder
   (drag the folder contents into "Add file → Upload files", or use `git push`).
3. Add your API key as a secret: **Settings → Secrets and variables → Actions → New repository secret**,
   name `RARE_API_KEY`, value your Data Manager key.
   *(Optional)* To use another dataset, add a variable `RARE_DATASET_ID` on the Variables tab.
4. Turn on Pages: **Settings → Pages → Build and deployment → Source: GitHub Actions**.
5. Run it once: **Actions → Refresh and publish dashboard → Run workflow**.
   When it finishes, your site is at `https://<your-user>.github.io/<repository>/`.

From then on it runs every day at 03:00 WIB. It downloads the dataset, rebuilds
`data.js`, and republishes the site only when there are new records. You can
press **Run workflow** any time for an immediate update.

## Option B — your own server or computer

Requires R with the `data.table` and `jsonlite` packages.

```bash
cd fish-forever-dashboard
RARE_API_KEY=your_key Rscript build_data.R
```

On Windows (PowerShell):

```powershell
$env:RARE_API_KEY = "your_key"; Rscript build_data.R
```

Then copy the folder to your web server, or open `index.html` directly. To keep it
current, schedule that command (cron on Linux, Task Scheduler on Windows).

To build from a CSV you already downloaded, set `RARE_CSV=path/to/file.csv` instead
of `RARE_API_KEY`.

## Sharing a filtered view

Filters and indicator choices are kept in the page address (after `#`), so you can
copy the link to share exactly what you are looking at, for example
`…/index.html#districts=South+East+Sulawesi%7CButon+Tengah&y0=2026&ind=cpue`.

## Methods (as shown under each plot)

- **Total landings**: catch weight per day, month or year. **CPUE**: catch ÷ fishing
  trips, where a trip is one fisher landing catch on one day.
- Lines are LOESS smooths (span 0.5, degree 2) with 95% bands. Trends are a Gaussian
  GLM of the value on date: Increased / Decreased when p < 0.05, else Stable.
- **Size structure**: length estimated per record from mean fish weight with
  W = a·L^b; L∞, Lmat and Lopt from Lmax (Froese & Binohlan 2000);
  Lmega = 1.1 × Lopt (Froese 2004). Species with fewer than 100 fish are not analysed.
