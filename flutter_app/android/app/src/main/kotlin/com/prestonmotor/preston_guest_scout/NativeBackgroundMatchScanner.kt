package com.prestonmotor.preston_guest_scout

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native Kotlin background inventory scanner so Android 10–15 devices can check
 * prestonmotor.com at 7:30 AM & 2:00 PM (or periodically in the background) without
 * requiring a foreground Activity, and immediately post full Android notifications
 * ("<Guest Name> - Match Found - <Vehicle Model>") whenever a new vehicle is found
 * AFTER a guest's first initial search.
 */
object NativeBackgroundMatchScanner {
    private const val PRESTON_BASE = "https://www.prestonmotor.com"
    private val isScanning = AtomicBoolean(false)

    fun runBackgroundScan(context: Context, slotLabel: String = "Scheduled Background Search"): Int {
        if (!isScanning.compareAndSet(false, true)) return 0
        try {
            val storeFile = File(context.filesDir, MainActivity.STORE_FILENAME)
            if (!storeFile.exists()) return 0
            val rawText = storeFile.readText()
            if (rawText.isBlank()) return 0

            val root = JSONObject(rawText)
            val guestsArr = root.optJSONArray("guests") ?: return 0
            val matchesArr = root.optJSONArray("matches") ?: JSONArray()
            val notifsArr = root.optJSONArray("notifications") ?: JSONArray()

            // Index existing matches and notifications
            val existingVinsByGuest = HashMap<String, MutableSet<String>>()
            for (i in 0 until matchesArr.length()) {
                val m = matchesArr.optJSONObject(i) ?: continue
                val gid = m.optString("guestId", "")
                val vin = m.optString("vin", "").trim()
                if (gid.isNotEmpty() && vin.isNotEmpty()) {
                    existingVinsByGuest.getOrPut(gid) { LinkedHashSet() }.add(vin)
                }
            }

            val existingNotifKeys = HashSet<String>()
            for (i in 0 until notifsArr.length()) {
                val n = notifsArr.optJSONObject(i) ?: continue
                existingNotifKeys.add("${n.optString("guestId", "")}::${n.optString("vin", "")}")
            }

            val isoFmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
            val nowIso = isoFmt.format(Date())

            var storeMutated = false
            var notificationsPosted = 0
            val newNotifsToPrepend = mutableListOf<JSONObject>()

            for (gi in 0 until guestsArr.length()) {
                val guest = guestsArr.optJSONObject(gi) ?: continue
                if (!guest.optBoolean("active", true)) continue
                val guestId = guest.optString("id", "").trim()
                val guestName = guest.optString("name", "Guest").trim().ifEmpty { "Guest" }
                val guestPhone = guest.optString("phone", "").trim()
                if (guestId.isEmpty()) continue

                // STRICT RULE: Only notify AFTER the guest's first initial search has completed!
                val hadCompletedInitialSearch = guest.optBoolean("initialSearchCompleted", false) ||
                    guest.optString("lastSearchedAt", "").trim().isNotEmpty()
                if (!hadCompletedInitialSearch) continue

                val seenSet = LinkedHashSet<String>()
                existingVinsByGuest[guestId]?.let { seenSet.addAll(it) }
                val rawSeen = guest.optJSONArray("seenMatchVins")
                if (rawSeen != null) {
                    for (si in 0 until rawSeen.length()) {
                        val sv = rawSeen.optString(si, "").trim()
                        if (sv.isNotEmpty()) seenSet.add(sv)
                    }
                }

                val targets = mutableListOf<JSONObject>()
                val rawTargets = guest.optJSONArray("vehicleTargets")
                if (rawTargets != null && rawTargets.length() > 0) {
                    for (ti in 0 until rawTargets.length()) {
                        rawTargets.optJSONObject(ti)?.let { targets.add(it) }
                    }
                } else {
                    targets.add(guest)
                }

                val matchedByVin = LinkedHashMap<String, Pair<JSONObject, JSONObject>>()
                for (target in targets) {
                    val candidates = fetchCandidatesForTarget(target)
                    for (cand in candidates) {
                        if (matchesTargetCriteria(target, cand)) {
                            val vin = cand.optString("vin", "").trim()
                            if (vin.isNotEmpty() && !matchedByVin.containsKey(vin)) {
                                matchedByVin[vin] = Pair(cand, target)
                            }
                        }
                    }
                }

                var guestChanged = false
                for ((vin, pair) in matchedByVin) {
                    val v = pair.first
                    val target = pair.second
                    val isBrandNewVin = seenSet.add(vin)
                    if (!isBrandNewVin) continue

                    guestChanged = true
                    storeMutated = true

                    val matchObj = JSONObject().apply {
                        put("id", "match-${System.currentTimeMillis()}-$vin")
                        put("guestId", guestId)
                        put("vin", vin)
                        put("stockNumber", v.optString("stockNumber", ""))
                        put("title", v.optString("title", ""))
                        if (v.has("year")) put("year", v.optInt("year"))
                        put("make", v.optString("make", ""))
                        put("model", v.optString("model", ""))
                        put("trim", v.optString("trim", ""))
                        put("condition", v.optString("condition", ""))
                        if (v.has("price")) put("price", v.optDouble("price"))
                        if (v.has("msrp")) put("msrp", v.optDouble("msrp"))
                        put("location", v.optString("location", "Preston Automotive Group"))
                        put("mileage", v.optInt("mileage", 0))
                        put("drivetrain", v.optString("drivetrain", ""))
                        put("engine", v.optString("engine", ""))
                        put("exteriorColor", v.optString("exteriorColor", ""))
                        put("interiorColor", v.optString("interiorColor", ""))
                        put("photoUrl", v.optString("photoUrl", ""))
                        put("listingUrl", v.optString("listingUrl", PRESTON_BASE))
                        put("matchedFeatures", JSONArray())
                        put("allHighlights", v.optJSONArray("highlights") ?: JSONArray())
                        put(
                            "agentSummary",
                            "Verified match found during $slotLabel on prestonmotor.com."
                        )
                        put("matchScore", 90)
                        put("foundAt", nowIso)
                        put("searchSlot", slotLabel)
                        put("lastSeenAt", nowIso)
                        put("targetId", target.optString("id", ""))
                        put("targetLabel", buildTargetLabel(target))
                    }
                    matchesArr.put(matchObj)

                    val notifKey = "$guestId::$vin"
                    if (existingNotifKeys.add(notifKey)) {
                        val makeStr = v.optString("make", "")
                        val modelStr = v.optString("model", "")
                        val titleStr = v.optString("title", "")
                        val modelLabel = extractVehicleModelLabel(makeStr, modelStr, titleStr)
                        val message = "$guestName - Match Found - $modelLabel"
                        val notifStrId = "notif-${System.currentTimeMillis()}-$vin"
                        val priceVal = if (v.has("price")) v.optDouble("price") else null
                        val locStr = v.optString("location", "Preston Automotive Group")

                        val notifObj = JSONObject().apply {
                            put("id", notifStrId)
                            put("guestId", guestId)
                            put("guestName", guestName)
                            put("guestPhone", guestPhone)
                            put("vin", vin)
                            put("vehicleModel", modelLabel)
                            put("vehicleTitle", titleStr)
                            put("message", message)
                            put("location", locStr)
                            if (priceVal != null && priceVal > 0) put("price", priceVal)
                            put("createdAt", nowIso)
                            put("read", false)
                        }
                        newNotifsToPrepend.add(notifObj)

                        if (notificationsPosted < 8) {
                            val posted = MatchNotificationHelper.postMatchNotification(
                                context = context,
                                notifId = notifStrId.hashCode() and 0x7fffffff,
                                guestId = guestId,
                                guestName = guestName,
                                guestPhone = guestPhone,
                                vehicleModel = modelLabel,
                                vehicleTitle = titleStr,
                                price = priceVal,
                                location = locStr,
                                fallbackTitle = message
                            )
                            if (posted) notificationsPosted++
                        }
                    }
                }

                if (guestChanged) {
                    val updatedSeenJson = JSONArray()
                    seenSet.forEach { updatedSeenJson.put(it) }
                    guest.put("seenMatchVins", updatedSeenJson)
                    guest.put("lastSearchedAt", nowIso)
                    guest.put("updatedAt", nowIso)
                }
            }

            if (storeMutated) {
                val mergedNotifs = JSONArray()
                for (n in newNotifsToPrepend) mergedNotifs.put(n)
                for (i in 0 until notifsArr.length()) {
                    notifsArr.optJSONObject(i)?.let { mergedNotifs.put(it) }
                }
                root.put("matches", matchesArr)
                root.put("notifications", mergedNotifs)
                storeFile.writeText(root.toString())
                refreshWidgetCounts(context, guestsArr, matchesArr)
            }

            return notificationsPosted
        } catch (_: Exception) {
            return 0
        } finally {
            isScanning.set(false)
        }
    }

    fun extractVehicleModelLabel(make: String, model: String, title: String): String {
        val cleanMake = make.trim()
        val cleanModel = model.trim()
        if (cleanMake.isNotEmpty() && cleanModel.isNotEmpty()) {
            return if (cleanModel.lowercase(Locale.US).startsWith(cleanMake.lowercase(Locale.US))) {
                cleanModel
            } else {
                "$cleanMake $cleanModel"
            }
        }
        if (cleanModel.isNotEmpty()) return cleanModel
        val cleanTitle = title.trim()
        if (cleanTitle.isNotEmpty()) {
            val stripped = cleanTitle
                .replaceFirst(
                    Regex("^(?:new|used|pre-owned|certified(?:\\s+pre-owned)?|cpo)\\s+", RegexOption.IGNORE_CASE),
                    ""
                )
                .replaceFirst(Regex("^\\d{4}\\s+"), "")
                .trim()
            if (stripped.isNotEmpty()) return stripped
            return cleanTitle
        }
        if (cleanMake.isNotEmpty()) return cleanMake
        return "Vehicle"
    }

    private fun buildTargetLabel(target: JSONObject): String {
        val parts = mutableListOf<String>()
        val cond = target.optString("condition", "Any").trim()
        if (cond.isNotEmpty() && !cond.equals("Any", ignoreCase = true)) parts.add(cond)
        val make = target.optString("make", "").trim()
        val model = target.optString("model", "").trim()
        val trim = target.optString("trim", "").trim()
        if (make.isNotEmpty()) parts.add(make)
        if (model.isNotEmpty()) parts.add(model)
        if (trim.isNotEmpty()) parts.add(trim)
        return if (parts.isEmpty()) "Target Vehicle" else parts.joinToString(" ")
    }

    private fun fetchCandidatesForTarget(target: JSONObject): List<JSONObject> {
        val cond = target.optString("condition", "Any").lowercase(Locale.US)
        val pageIds = when {
            cond == "new" -> listOf(1446609)
            cond == "pre-owned" || cond == "used" || cond == "cpo" || cond == "certified pre-owned" ->
                listOf(1446611)
            else -> listOf(1446609, 1446611)
        }
        val make = target.optString("make", "").trim()
        val model = target.optString("model", "").trim()
        val byVin = LinkedHashMap<String, JSONObject>()

        for (pid in pageIds) {
            val params = LinkedHashMap<String, String>()
            if (make.isNotEmpty()) params["Make"] = make
            if (make.isNotEmpty() && model.isNotEmpty()) params["Model"] = model

            var totalPages = 1
            var page = 1
            while (page <= totalPages && page <= 12) {
                val res = querySinglePage(pid, params, page)
                totalPages = res.second
                for (v in res.first) {
                    val vin = v.optString("vin", "")
                    if (vin.isNotEmpty() && !byVin.containsKey(vin)) {
                        byVin[vin] = v
                    }
                }
                page++
            }
        }
        return byVin.values.toList()
    }

    private fun querySinglePage(
        pageId: Int,
        params: Map<String, String>,
        pageNumber: Int
    ): Pair<List<JSONObject>, Int> {
        val qp = LinkedHashMap<String, String>(params)
        qp["pn"] = "96"
        qp["host"] = "www.prestonmotor.com"
        if (pageNumber > 1) qp["pt"] = pageNumber.toString()

        val queryString = qp.entries.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }
        val urlStr =
            "$PRESTON_BASE/api/vhcliaa/vehicle-pages/cosmos/srp/vehicles/19398/$pageId?$queryString"

        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 15_000
                readTimeout = 15_000
                setRequestProperty(
                    "User-Agent",
                    "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36"
                )
                setRequestProperty("Accept", "application/json")
            }
            if (conn.responseCode != 200) {
                return Pair(emptyList(), 1)
            }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val data = JSONObject(body)
            val cards = data.optJSONArray("DisplayCards") ?: JSONArray()
            val out = mutableListOf<JSONObject>()
            for (i in 0 until cards.length()) {
                val card = cards.optJSONObject(i) ?: continue
                if (card.optBoolean("IsAdCard", false)) continue
                val vc = card.optJSONObject("VehicleCard") ?: continue
                parseVehicleCard(vc)?.let { out.add(it) }
            }
            val paging = data.optJSONObject("Paging")?.optJSONObject("PaginationDataModel")
            val totalCount = paging?.optInt("TotalCount", out.size) ?: out.size
            val pageSize = (paging?.optInt("PageSize", 96) ?: 96).coerceAtLeast(1)
            val calcPages = (totalCount + pageSize - 1) / pageSize
            val totalPages = (paging?.optInt("TotalPages", calcPages) ?: calcPages).coerceIn(1, 15)
            Pair(out, totalPages)
        } catch (_: Exception) {
            Pair(emptyList(), 1)
        } finally {
            conn?.disconnect()
        }
    }

    private fun parseVehicleCard(vc: JSONObject): JSONObject? {
        val vin = vc.optString("VehicleVin", "").trim()
        if (vin.isEmpty()) return null

        var finalPrice: Double? = null
        var msrp: Double? = null
        val b64 = vc.optString("VehiclePriceLibrary", "")
        if (b64.isNotEmpty()) {
            try {
                val decoded = String(Base64.decode(b64, Base64.DEFAULT), Charsets.UTF_8)
                val kv = HashMap<String, Double>()
                for (entry in decoded.split(";")) {
                    val idx = entry.indexOf(':')
                    if (idx == -1) continue
                    val k = entry.substring(0, idx).trim()
                    val v = entry.substring(idx + 1).trim().toDoubleOrNull()
                    if (v != null && v > 0.0) kv[k] = v
                }
                msrp = kv["MSRP"] ?: kv["calc_MSRP"]
                finalPrice = kv["calc_FINAL PRICE"]
                    ?: kv["Internet Price"]
                    ?: kv["Selling Price"]
                    ?: kv["calc_INTERNET PRICE"]
                    ?: msrp
            } catch (_: Exception) {
            }
        }

        val vcInternet = vc.optDouble("VehicleInternetPrice", 0.0)
        val vcMsrp = vc.optDouble("VehicleMsrp", 0.0)
        if (finalPrice == null) {
            finalPrice = when {
                vcInternet > 0.0 -> vcInternet
                vcMsrp > 0.0 -> vcMsrp
                else -> null
            }
        }
        if (msrp == null && vcMsrp > 0.0) msrp = vcMsrp

        val highlights = JSONArray()
        val rawHighlights = vc.optJSONObject("VehicleHighlightsModel")?.optJSONArray("Highlights")
        if (rawHighlights != null) {
            for (i in 0 until rawHighlights.length()) {
                highlights.put(rawHighlights.optString(i, ""))
            }
        }

        val city = vc.optString("DealerLocatedAtCity", "").trim()
        val state = vc.optString("DealerLocatedAtState", "").trim()
        val branch = vc.optString(
            "VehicleLocationLabel",
            vc.optString("VehicleLocation", vc.optString("DealerName", "Preston Automotive Group"))
        ).trim()
        val cityState = listOf(city, state).filter { it.isNotEmpty() }.joinToString(", ")
        val location = if (cityState.isEmpty() || branch.contains(city, ignoreCase = true)) {
            branch
        } else {
            "$branch ($cityState)"
        }

        val imgModel = vc.optJSONObject("VehicleImageModel")
        val photoList = imgModel?.optJSONObject("VehicleImageCarouselModel")?.optJSONArray("PhotoList")
        val rawPhoto = if (photoList != null && photoList.length() > 0) {
            photoList.optString(0, "")
        } else {
            imgModel?.optString("VehiclePhotoSrc", "") ?: ""
        }
        val photoUrl = when {
            rawPhoto.isEmpty() -> ""
            rawPhoto.startsWith("http") -> rawPhoto
            else -> "$PRESTON_BASE$rawPhoto"
        }
        val rawDetail = imgModel?.optString("VehicleDetailUrl", PRESTON_BASE) ?: PRESTON_BASE
        val listingUrl = if (rawDetail.startsWith("http")) rawDetail else "$PRESTON_BASE$rawDetail"

        val isCpo = vc.optBoolean("VehicleCpo", false)
        val condition = if (isCpo) {
            "Certified Pre-Owned"
        } else {
            vc.optString("VehicleCondition", if (vc.optString("VehicleType") == "new") "New" else "Pre-Owned")
        }

        val rawDt = "${vc.optString("VehicleDriveTrain", "")} $highlights".uppercase(Locale.US)
        val drivetrain = when {
            rawDt.contains("4X4") || rawDt.contains("FOUR WHEEL DRIVE") || rawDt.contains("4WD") -> "4WD"
            rawDt.contains("ALL WHEEL DRIVE") || rawDt.contains("ALL-WHEEL") || rawDt.contains("AWD") -> "AWD"
            rawDt.contains("FWD") -> "FWD"
            rawDt.contains("RWD") -> "RWD"
            else -> ""
        }

        return JSONObject().apply {
            put("vin", vin)
            put("stockNumber", vc.optString("VehicleStockNumber", ""))
            put("title", vc.optString("VehicleName", ""))
            val yr = vc.optInt("VehicleYear", 0)
            if (yr > 0) put("year", yr)
            put("make", vc.optString("VehicleMake", ""))
            put("model", vc.optString("VehicleModel", ""))
            put("trim", vc.optString("VehicleTrim", ""))
            put("condition", condition)
            if (finalPrice != null && finalPrice > 0.0) put("price", finalPrice)
            if (msrp != null && msrp > 0.0) put("msrp", msrp)
            put("location", location)
            put("mileage", vc.optInt("VehicleMileage", 0))
            put("drivetrain", drivetrain)
            put("engine", vc.optString("VehicleEngine", ""))
            put("exteriorColor", vc.optString("ExteriorColorLabel", ""))
            put("interiorColor", vc.optString("InteriorColorLabel", ""))
            put("photoUrl", photoUrl)
            put("listingUrl", listingUrl)
            put("highlights", highlights)
        }
    }

    private fun matchesTargetCriteria(target: JSONObject, v: JSONObject): Boolean {
        val make = target.optString("make", "").trim().lowercase(Locale.US)
        if (make.isNotEmpty()) {
            val hay = "${v.optString("make")} ${v.optString("title")}".lowercase(Locale.US)
            if (!hay.contains(make)) return false
        }
        val model = target.optString("model", "").trim().lowercase(Locale.US)
        if (model.isNotEmpty()) {
            val tokens = model.replace("-", " ").split(Regex("\\s+")).filter { it.isNotEmpty() }
            val hay = "${v.optString("model")} ${v.optString("title")} ${v.optString("trim")}"
                .lowercase(Locale.US)
                .replace("-", " ")
            if (!tokens.all { hay.contains(it) }) return false
        }
        val trim = target.optString("trim", "").trim().lowercase(Locale.US)
        if (trim.isNotEmpty()) {
            val hay = "${v.optString("trim")} ${v.optString("title")}".lowercase(Locale.US)
            if (!hay.contains(trim)) return false
        }
        val yr = v.optInt("year", 0)
        val minYear = target.optInt("minYear", 0)
        val maxYear = target.optInt("maxYear", 0)
        if (minYear > 0 && yr > 0 && yr < minYear) return false
        if (maxYear > 0 && yr > 0 && yr > maxYear) return false

        val maxPrice = target.optDouble("maxPrice", 0.0)
        if (maxPrice > 0.0) {
            val pr = v.optDouble("price", 0.0)
            val msrp = v.optDouble("msrp", 0.0)
            val effective = if (pr > 0.0) pr else msrp
            if (effective <= 0.0 || effective > maxPrice) return false
        }

        val maxMileage = target.optInt("maxMileage", 0)
        if (maxMileage > 0) {
            val miles = v.optInt("mileage", 0)
            if (miles > maxMileage) return false
        }

        val dt = target.optString("drivetrain", "Any").trim().uppercase(Locale.US)
        if (dt.isNotEmpty() && dt != "ANY") {
            val vDt = v.optString("drivetrain", "").uppercase(Locale.US)
            if (vDt.isNotEmpty()) {
                val ok = when (dt) {
                    "4WD", "AWD", "4WD/AWD" -> vDt.contains("4WD") || vDt.contains("AWD")
                    else -> vDt.contains(dt)
                }
                if (!ok) return false
            }
        }
        return true
    }

    private fun refreshWidgetCounts(
        context: Context,
        guestsArr: JSONArray,
        matchesArr: JSONArray
    ) {
        try {
            val countsByGuest = HashMap<String, Int>()
            for (i in 0 until matchesArr.length()) {
                val m = matchesArr.optJSONObject(i) ?: continue
                val gid = m.optString("guestId", "")
                if (gid.isNotEmpty()) {
                    countsByGuest[gid] = (countsByGuest[gid] ?: 0) + 1
                }
            }
            val guestsList = mutableListOf<JSONObject>()
            for (i in 0 until guestsArr.length()) {
                guestsArr.optJSONObject(i)?.let { guestsList.add(it) }
            }
            guestsList.sortByDescending { it.optString("createdAt", "") }

            val topTen = JSONArray()
            for (g in guestsList.take(10)) {
                val gid = g.optString("id", "")
                topTen.put(
                    JSONObject().apply {
                        put("id", gid)
                        put("name", g.optString("name", ""))
                        put("targetSummary", buildTargetLabel(g))
                        put("matchCount", countsByGuest[gid] ?: 0)
                        put("createdAt", g.optString("createdAt", ""))
                    }
                )
            }
            val prefs = context.getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().putString(MainActivity.KEY_RECENT_TEN_JSON, topTen.toString()).apply()

            val appWidgetManager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, PrestonGuestWidgetProvider::class.java)
            val appWidgetIds = appWidgetManager.getAppWidgetIds(component)
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.widget_guest_list)
            PrestonGuestWidgetProvider.updateAllWidgets(context)
        } catch (_: Exception) {
        }
    }
}
