# Fish Forever catch dashboard — data refresh
#
# Downloads the catch dataset from Rare's Data Manager (data.rare.org),
# aggregates it into the tables the dashboard reads, and writes them to
# data/data.js. Only totals are written: no fisher or buyer names or IDs.
#
# Run from the project folder:
#   RARE_API_KEY=xxxx Rscript R/build_data.R
#
# Environment variables
#   RARE_API_KEY     your Data Manager API key (required; keep it secret)
#   RARE_DATASET_ID  dataset id (default 91AmXtp0_5Gb0hD7)
#   RARE_CSV         optional path to an already-downloaded CSV (skips the download)

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

dataset_id <- Sys.getenv("RARE_DATASET_ID")
if (!nzchar(dataset_id)) dataset_id <- "91AmXtp0_5Gb0hD7"
api_key    <- Sys.getenv("RARE_API_KEY", "")
local_csv  <- Sys.getenv("RARE_CSV", "")
out_file   <- file.path("data", "data.js")
base_year  <- 2019L   # the dashboard counts months and days from Jan 1, 2019
outside    <- "Outside managed access areas"

# ---- 1. Download -------------------------------------------------------------
if (nzchar(local_csv)) {
  src <- local_csv
} else {
  if (!nzchar(api_key)) stop("Set RARE_API_KEY (or RARE_CSV to use a local file).")
  src <- tempfile(fileext = ".csv")
  url <- sprintf("https://data.rare.org/api/datasets/%s?api_key=%s", dataset_id, api_key)
  message("Downloading dataset ", dataset_id, " ...")
  status <- download.file(url, src, mode = "wb", quiet = TRUE)
  if (status != 0) stop("Download failed with status ", status)
}
raw <- fread(src, colClasses = "character", na.strings = NULL, encoding = "UTF-8", showProgress = FALSE)
message("Read ", nrow(raw), " catch records.")

num <- function(x) suppressWarnings(as.numeric(x))
blank_as <- function(x, value) ifelse(is.na(x) | x == "", value, x)

# Keep only the columns needed, renamed so nothing clashes
d <- raw[, .(
  date_str   = substr(date, 1, 10),
  year       = as.integer(substr(date, 1, 4)),
  month      = as.integer(substr(date, 6, 7)),
  fisher     = fisher_id,
  kg         = fifelse(is.na(num(weight_kg)), 0, num(weight_kg)),
  idr        = fifelse(is.na(num(total_price_local)), 0, num(total_price_local)),
  unit       = blank_as(buying_unit, "Not recorded"),
  gear       = blank_as(gear_type, "Not recorded"),
  area_key   = paste(level1_name, level2_name, blank_as(ma_name, outside), sep = "|"),
  species, family, label,
  fish_count = num(count),
  lw_a_raw   = a, lw_b_raw = b, lmax_raw = lmax,
  basis      = measurement_basis
)]
rm(raw)
d <- d[!is.na(year)]
if (any(d$year < base_year)) {
  warning(sum(d$year < base_year), " records before ", base_year, " are left out.")
  d <- d[year >= base_year]
}
d[, `:=`(
  m   = (year - base_year) * 12L + month - 1L,
  day = as.integer(as.Date(date_str) - as.Date(sprintf("%d-01-01", base_year)))
)]

# Index tables, sorted the same way every run (C-locale order)
areas_v <- sort(unique(d$area_key), method = "radix")
units_v <- sort(unique(d$unit), method = "radix")
gears_v <- sort(unique(d$gear), method = "radix")
d[, `:=`(ai = match(area_key, areas_v) - 1L, bi = match(unit, units_v) - 1L, gi = match(gear, gears_v) - 1L)]

# Most frequent value in a group (first seen wins a tie)
top1 <- function(x) { t <- table(factor(x, levels = unique(x))); names(t)[which.max(t)] }

# ---- 2. Tables ---------------------------------------------------------------
# Catch by month, area, buying unit and gear
cube <- d[, .(kg = round(sum(kg), 1), idr = round(sum(idr)), n = .N), by = .(m, a = ai, b = bi, g = gi)]

# Buying units with their usual species, family and local name
bu <- d[, .(species = top1(species), family = top1(family), local_name = top1(label)), by = .(b = bi, buying_unit = unit)]
bu[is.na(family) | family == "", family := "Unknown"]
setorder(bu, b)

# Places, with distinct fishers per area across all years (a count only)
ar <- d[, .(fishers_all_years = uniqueN(fisher)), by = .(a = ai)]
ar[, c("province", "district", "managed_area") := tstrsplit(areas_v[a + 1L], "|", fixed = TRUE)]
ar <- ar[order(a), .(a, province, district, managed_area, fishers_all_years)]

gears <- data.table(g = seq_along(gears_v) - 1L, gear = gears_v)

summary_t <- data.table(
  records = nrow(d),
  species = uniqueN(d[species != "", species]),
  fishers = uniqueN(d$fisher),
  first_date = min(d$date_str),
  last_date = max(d$date_str),
  total_catch_kg = round(sum(d$kg)),
  total_value_idr = round(sum(d$idr))
)

# Daily catch and fishing trips (a trip = one fisher landing catch on one day)
daily_catch <- d[, .(kg = round(sum(kg), 1)), by = .(d = day, a = ai, b = bi)]
daily_trips <- d[, .(trips = uniqueN(fisher)), by = .(d = day, a = ai)]

# Reference lengths per buying unit from its most common a, b and Lmax
# L-inf, Lmat, Lopt: Froese & Binohlan (2000); Lmega = 1.1 x Lopt (Froese 2004)
pr <- d[, .(key = top1(paste(lw_a_raw, lw_b_raw, lmax_raw, sep = "|"))), by = .(b = bi)]
pr[, c("lw_a", "lw_b", "lmax_cm") := lapply(tstrsplit(key, "|", fixed = TRUE, keep = 1:3), num)]
pr[, linf_cm := 10^(0.044 + 0.9841 * log10(lmax_cm))]
pr[, `:=`(lmat_cm = 10^(0.8979 * log10(linf_cm) - 0.0782), lopt_cm = 10^(1.0421 * log10(linf_cm) - 0.2742))]
pr[, lmega_cm := lopt_cm * 1.1]
for (col in c("linf_cm", "lmat_cm", "lopt_cm", "lmega_cm")) set(pr, j = col, value = round(pr[[col]], 1))
bad <- is.na(pr$lmax_cm) | pr$lmax_cm <= 0
for (col in c("lw_a", "lw_b", "lmax_cm", "linf_cm", "lmat_cm", "lopt_cm", "lmega_cm")) set(pr, i = which(bad), j = col, value = NA_real_)
pr <- pr[order(b), .(b, lw_a, lw_b, lmax_cm, linf_cm, lmat_cm, lopt_cm, lmega_cm)]

# Estimated length frequencies: mean fish weight per record -> L = (W / a)^(1 / b)
# Only records sold by weight with a fish count; lengths over 1.5 x Lmax are dropped
s <- d[, .(b = bi, a = ai, year, c = fish_count, w = kg, la = num(lw_a_raw), lb = num(lw_b_raw), lm = num(lmax_raw), basis)]
s <- s[basis == "weight" & c > 0 & w > 0 & la > 0 & lb > 0 & lm > 0]
s[, L := (w * 1000 / c / la)^(1 / lb)]
s <- s[is.finite(L) & L > 0 & L <= lm * 1.5]
size_bins <- s[, .(fish = sum(c)), by = .(b, a, year, len_cm = floor(L))]
message("Length estimates from ", nrow(s), " records.")

# ---- 3. Write data/data.js ---------------------------------------------------
as_csv <- function(x) {
  tf <- tempfile(fileext = ".csv")
  fwrite(x, tf, na = "", scipen = 50)
  paste(readLines(tf, encoding = "UTF-8"), collapse = "\n")
}
payload <- list(
  generated = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  source = paste0("Rare Fish Forever dataset ", dataset_id, " (data.rare.org)"),
  base_year = base_year,
  files = list(
    catch_cube = as_csv(cube),
    buying_units = as_csv(bu),
    areas = as_csv(ar),
    gears = as_csv(gears),
    summary = as_csv(summary_t),
    size_bins = as_csv(size_bins),
    species_params = as_csv(pr),
    daily_catch = as_csv(daily_catch),
    daily_trips = as_csv(daily_trips)
  )
)
dir.create(dirname(out_file), showWarnings = FALSE, recursive = TRUE)
# Leave the file alone when the data hasn't changed, so the site only redeploys on new records
new_files <- toJSON(payload$files, auto_unbox = TRUE)
if (file.exists(out_file)) {
  old <- paste(readLines(out_file, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  old_json <- sub("^window\\.FF_DATA = ", "", sub(";\\s*$", "", old))
  old_files <- tryCatch(toJSON(fromJSON(old_json, simplifyVector = FALSE)$files, auto_unbox = TRUE), error = function(e) "")
  if (identical(as.character(old_files), as.character(new_files))) {
    message("No new data; ", out_file, " left unchanged.")
    quit(save = "no", status = 0)
  }
}
writeLines(paste0("window.FF_DATA = ", toJSON(payload, auto_unbox = TRUE), ";"), out_file, useBytes = TRUE)
message("Wrote ", out_file, " (", round(file.size(out_file) / 1e6, 1), " MB): ",
        nrow(cube), " cube rows, ", nrow(daily_catch), " daily rows, ", nrow(size_bins), " length bins.")
