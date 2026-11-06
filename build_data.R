# Fish Forever catch dashboard — data refresh
#
# Pulls two sources and writes the aggregated tables the dashboard reads to data.js:
#   1. Digital records from Rare's Data Manager (data.rare.org)  — needs RARE_API_KEY
#   2. Paper-based records from the public Google Sheet         — no key needed
# Only totals are written: no fisher or buyer names or IDs.
#
# Run from the project folder:
#   RARE_API_KEY=xxxx Rscript build_data.R
#
# Environment variables
#   RARE_API_KEY     Data Manager API key (keep it secret). Without it only the paper sheet is used.
#   RARE_DATASET_ID  Data Manager dataset id (default 91AmXtp0_5Gb0hD7)
#   PAPER_SHEET_ID   Google Sheet id (default 1Q_L8j4sc1ynklrdROXCk8lJsRqAEZg83cPvDL4xjENc)
#   PAPER_SHEET_GID  tab id inside the sheet (default 0, the "Asli" tab)
#   RARE_CSV / PAPER_CSV  optional paths to already-downloaded CSVs (skip the downloads)

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

env <- function(name, default = "") { v <- Sys.getenv(name); if (nzchar(v)) v else default }
dataset_id <- env("RARE_DATASET_ID", "91AmXtp0_5Gb0hD7")
api_key    <- env("RARE_API_KEY")
sheet_id   <- env("PAPER_SHEET_ID", "1Q_L8j4sc1ynklrdROXCk8lJsRqAEZg83cPvDL4xjENc")
sheet_gid  <- env("PAPER_SHEET_GID", "0")
out_file   <- "data.js"
outside    <- "Outside managed access areas"

`%||%` <- function(a, b) if (is.null(a)) b else a
num <- function(x) suppressWarnings(as.numeric(gsub(",", "", x, fixed = TRUE)))
blank <- function(x) is.na(x) | x == "" | x == "NA" | x == "#N/A"
blank_as <- function(x, value) ifelse(blank(x), value, x)
sentence <- function(x) { x <- tolower(trimws(x)); paste0(toupper(substr(x, 1, 1)), substr(x, 2, nchar(x))) }
fetch <- function(url, what) {
  f <- tempfile(fileext = ".csv")
  message("Downloading ", what, " ...")
  st <- tryCatch(download.file(url, f, mode = "wb", quiet = TRUE, method = "libcurl"), error = function(e) 1)
  if (st != 0 || !file.exists(f) || file.size(f) < 100) return(NULL)
  f
}

# ---- 1. Digital records (Data Manager) ---------------------------------------
digital <- NULL
dm_src <- env("RARE_CSV")
if (!nzchar(dm_src) && nzchar(api_key))
  dm_src <- fetch(sprintf("https://data.rare.org/api/datasets/%s?api_key=%s", dataset_id, api_key), "Data Manager dataset") %||% ""
if (nzchar(dm_src)) {
  raw <- fread(dm_src, colClasses = "character", na.strings = NULL, encoding = "UTF-8", showProgress = FALSE)
  digital <- raw[, .(
    s = 0L,
    date_str = substr(date, 1, 10),
    province = level1_name, district = level2_name, ma = blank_as(ma_name, outside),
    fisher = paste0("d", fisher_id),
    trip = paste0("d", fisher_id, "|", substr(date, 1, 10)),
    unit = sentence(blank_as(buying_unit, "Not recorded")),
    species, family = blank_as(family, "Unknown"), local = label,
    gear = blank_as(gear_type, "Not recorded"),
    kg = fifelse(is.na(num(weight_kg)), 0, num(weight_kg)),
    idr = fifelse(is.na(num(total_price_local)), 0, num(total_price_local)),
    fish = num(count), length_cm = NA_real_,
    lw_a = num(a), lw_b = num(b), lmax = num(lmax), lw_key = paste(a, b, lmax, sep = "|"),
    by_weight = measurement_basis == "weight"
  )]
  rm(raw)
  message("Digital records: ", nrow(digital))
} else message("No RARE_API_KEY or RARE_CSV: digital records skipped.")

# ---- 2. Paper-based records (Google Sheet) ----------------------------------
paper <- NULL
pp_src <- env("PAPER_CSV")
if (!nzchar(pp_src))
  pp_src <- fetch(sprintf("https://docs.google.com/spreadsheets/d/%s/export?format=csv&gid=%s", sheet_id, sheet_gid), "paper-based Google Sheet") %||% ""
if (nzchar(pp_src)) {
  raw <- fread(pp_src, colClasses = "character", na.strings = NULL, encoding = "UTF-8", showProgress = FALSE)
  setnames(raw, make.unique(names(raw)))
  col <- function(n) raw[[n]]
  y <- as.integer(num(col("year"))); mo <- as.integer(num(col("month"))); dd <- as.integer(num(col("day")))
  ok <- !is.na(y) & y > 2000 & !is.na(mo) & mo >= 1 & mo <= 12 & !is.na(dd) & dd >= 1 & dd <= 31
  # Sheet names mapped to the Data Manager's names so places line up
  prov_map <- c("Sulawesi Tenggara" = "South East Sulawesi", "Jakarta" = "DKI Jakarta", "Papua Barat" = "South West Papua")
  dist_map <- c("Wabula" = "Buton")
  prov <- col("province"); prov <- ifelse(prov %in% names(prov_map), prov_map[prov], prov)
  dist <- col("fisher_install"); dist <- ifelse(dist %in% names(dist_map), dist_map[dist], dist)
  paper <- data.table(
    s = 1L,
    date_str = sprintf("%04d-%02d-%02d", y, mo, dd),
    province = prov, district = dist, ma = blank_as(col("managed_access"), outside),
    fisher = paste0("p", col("fisher_name"), "|", col("fisher_community")),
    trip = paste0("p", col("trip_id")),
    unit = sentence(blank_as(col("fish_species"), "Not recorded")),
    species = col("fish_species"), family = blank_as(trimws(col("fish_family")), "Unknown"), local = trimws(col("fish_name")),
    gear = blank_as(trimws(col("gear (INA)")), "Not recorded"),
    kg = fifelse(is.na(num(col("weight (Kg)"))), 0, num(col("weight (Kg)"))),
    idr = fifelse(is.na(num(col("total_price (Rp)"))), 0, num(col("total_price (Rp)"))),
    fish = num(col("count")), length_cm = num(col("length (cm)")),
    lw_a = NA_real_, lw_b = NA_real_, lmax = NA_real_, lw_key = NA_character_, by_weight = FALSE
  )[ok]
  rm(raw)
  message("Paper records: ", nrow(paper))
} else message("Google Sheet could not be downloaded: paper records skipped.")

d <- rbindlist(list(digital, paper), use.names = TRUE)
if (!nrow(d)) stop("No data from either source.")
d[, `:=`(year = as.integer(substr(date_str, 1, 4)), month = as.integer(substr(date_str, 6, 7)))]
d <- d[!is.na(year) & !is.na(month)]
base_year <- min(d$year)
d[, `:=`(
  m = (year - base_year) * 12L + month - 1L,
  day = as.integer(as.Date(date_str) - as.Date(sprintf("%d-01-01", base_year))),
  area_key = paste(province, district, ma, sep = "|")
)]
d <- d[!is.na(day)]

areas_v <- sort(unique(d$area_key), method = "radix")
units_v <- sort(unique(d$unit), method = "radix")
gears_v <- sort(unique(d$gear), method = "radix")
d[, `:=`(ai = match(area_key, areas_v) - 1L, bi = match(unit, units_v) - 1L, gi = match(gear, gears_v) - 1L)]
top1 <- function(x) { x <- x[!blank(x)]; if (!length(x)) return(""); t <- table(factor(x, levels = unique(x))); names(t)[which.max(t)] }

# ---- 3. Tables (s = 0 digital, 1 paper) --------------------------------------
cube <- d[, .(kg = round(sum(kg), 1), idr = round(sum(idr)), n = .N), by = .(m, a = ai, b = bi, g = gi, s)]

bu <- d[, .(species = top1(species), family = top1(family), local_name = top1(local)), by = .(b = bi, buying_unit = unit)]
bu[family == "", family := "Unknown"]
setorder(bu, b)

# Places, with distinct fishers per area across all years for each source (counts only)
fa <- d[, .(f = uniqueN(fisher)), by = .(a = ai, s)]
ar <- data.table(a = seq_along(areas_v) - 1L)
ar[, c("province", "district", "managed_area") := tstrsplit(areas_v, "|", fixed = TRUE)]
ar[fa[s == 0L], fishers_digital := i.f, on = "a"]
ar[fa[s == 1L], fishers_paper := i.f, on = "a"]
ar[is.na(fishers_digital), fishers_digital := 0L][is.na(fishers_paper), fishers_paper := 0L]

gears <- data.table(g = seq_along(gears_v) - 1L, gear = gears_v)

summary_t <- d[, .(
  records = .N,
  species = uniqueN(species[!blank(species)]),
  fishers = uniqueN(fisher),
  first_date = min(date_str), last_date = max(date_str),
  total_catch_kg = round(sum(kg)), total_value_idr = round(sum(idr))
), by = s][order(s)]

# Daily catch and fishing trips. Digital: a trip is one fisher landing on one day.
# Paper: a trip is one trip_id in the sheet.
daily_catch <- d[, .(kg = round(sum(kg), 1)), by = .(d = day, a = ai, b = bi, s)]
daily_trips <- d[, .(trips = uniqueN(trip)), by = .(d = day, a = ai, s)]

# Reference lengths from the Data Manager's most common a, b and Lmax per species
# L-inf, Lmat, Lopt: Froese & Binohlan (2000); Lmega = 1.1 x Lopt (Froese 2004)
pr <- data.table(b = seq_along(units_v) - 1L)
lw <- d[s == 0L, .(key = top1(lw_key)), by = .(b = bi)]
pr[lw, key := i.key, on = "b"]
pr[, c("lw_a", "lw_b", "lmax_cm") := lapply(tstrsplit(fifelse(is.na(key), "||", key), "|", fixed = TRUE, keep = 1:3), num)]
pr[, linf_cm := 10^(0.044 + 0.9841 * log10(lmax_cm))]
pr[, `:=`(lmat_cm = 10^(0.8979 * log10(linf_cm) - 0.0782), lopt_cm = 10^(1.0421 * log10(linf_cm) - 0.2742))]
pr[, lmega_cm := lopt_cm * 1.1]
for (col in c("linf_cm", "lmat_cm", "lopt_cm", "lmega_cm")) set(pr, j = col, value = round(pr[[col]], 1))
bad <- is.na(pr$lmax_cm) | pr$lmax_cm <= 0
for (col in c("lw_a", "lw_b", "lmax_cm", "linf_cm", "lmat_cm", "lopt_cm", "lmega_cm")) set(pr, i = which(bad), j = col, value = NA_real_)
pr <- pr[order(b), .(b, lw_a, lw_b, lmax_cm, linf_cm, lmat_cm, lopt_cm, lmega_cm)]

# Length frequencies (fish per 1 cm class)
#  digital: estimated per record from mean fish weight, L = (W / a)^(1 / b); records sold by weight
#           with a fish count; lengths over 1.5 x Lmax dropped
#  paper:   the measured length column, each record counted `count` times
sd <- d[s == 0L & by_weight & fish > 0 & kg > 0 & lw_a > 0 & lw_b > 0 & lmax > 0]
sd[, L := (kg * 1000 / fish / lw_a)^(1 / lw_b)]
sd <- sd[is.finite(L) & L > 0 & L <= lmax * 1.5]
sp <- d[s == 1L & fish > 0 & length_cm > 0, .(bi, ai, year, s, fish, L = length_cm)]
size_bins <- rbindlist(list(sd[, .(bi, ai, year, s, fish, L)], sp))[, .(fish = sum(fish)), by = .(b = bi, a = ai, year, s, len_cm = floor(L))]
message("Length classes from ", nrow(sd), " digital and ", nrow(sp), " paper records.")

# ---- 4. Write data.js --------------------------------------------------------
as_csv <- function(x) {
  tf <- tempfile(fileext = ".csv")
  fwrite(x, tf, na = "", scipen = 50)
  paste(readLines(tf, encoding = "UTF-8"), collapse = "\n")
}
sources <- c(if (!is.null(digital)) "digital", if (!is.null(paper)) "paper")
payload <- list(
  generated = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  source = paste0("Rare Fish Forever: Data Manager dataset ", dataset_id, " and paper-based Google Sheet ", sheet_id),
  base_year = base_year,
  sources = sources,
  files = list(
    catch_cube = as_csv(cube), buying_units = as_csv(bu), areas = as_csv(ar), gears = as_csv(gears),
    summary = as_csv(summary_t), size_bins = as_csv(size_bins), species_params = as_csv(pr),
    daily_catch = as_csv(daily_catch), daily_trips = as_csv(daily_trips)
  )
)
# Leave the file alone when nothing changed, so the site only redeploys on new records
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
message("Wrote ", out_file, " (", round(file.size(out_file) / 1e6, 1), " MB) from ", paste(sources, collapse = " + "), ": ",
        nrow(cube), " cube rows, ", nrow(daily_catch), " daily rows, ", nrow(size_bins), " length classes.")
