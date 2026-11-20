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
        val qualifiers = mutableListOf<String>()
        val cab = target.optString("cabStyle", "").trim()
        val bed = target.optString("bedLength", "").trim()
        if (cab.isNotEmpty()) qualifiers.add(cab)
        if (bed.isNotEmpty()) qualifiers.add("${bed.removeSuffix("'")} ft Bed")
        val base = parts.joinToString(" ")
        return when {
            base.isEmpty() && qualifiers.isEmpty() -> "Target Vehicle"
            qualifiers.isEmpty() -> base
            base.isEmpty() -> qualifiers.joinToString(" • ")
            else -> "$base • ${qualifiers.joinToString(" • ")}"
        }
    }

    private fun bedLengthToFacetValues(bedLength: String): List<String> =
        when (bedLength.trim().removeSuffix("'")) {
            "5" -> listOf("5-ft bed")
            "5.5" -> listOf("5-1/2' Box", "5.5-Ft.")
            "6" -> listOf("6-ft bed")
            "6.5" -> listOf("6-1/2' Box")
            "6.75" -> listOf("6 3/4' Box")
            "8" -> listOf("8' Box")
            else -> emptyList()
        }

    private fun expandModelVariants(make: String, model: String): List<String> {
        val m = model.trim()
        if (m.isEmpty()) return emptyList()
        val out = LinkedHashSet<String>()
        out.add(m)
        val sd = Regex("^f[\\s-]*([2345]50)$", RegexOption.IGNORE_CASE).matchEntire(m)
        if (sd != null) {
            val num = sd.groupValues[1]
            out.add("F-$num")
            out.add("Super Duty F-$num")
            out.add("Super Duty F-$num SRW")
            out.add("Super Duty F-$num DRW")
            out.add("F-$num Super Duty")
        } else if (Regex("^f[\\s-]*150$", RegexOption.IGNORE_CASE).matches(m)) {
            out.add("F-150")
        } else if (Regex("^cx[\\s-]*(\\d+)$", RegexOption.IGNORE_CASE).matches(m)) {
            val num = Regex("\\d+").find(m)?.value ?: ""
            out.add("CX-$num")
            out.add("Mazda CX-$num")
        } else if (make.equals("Ram", ignoreCase = true) && Regex("^(1500|2500|3500)$").matches(m)) {
            out.add("Ram $m")
        }
        return out.toList()
    }

    private fun inferMakeFromModel(rawMake: String, rawModel: String): String {
        val cleanMake = rawMake.trim()
        if (cleanMake.isNotEmpty()) return cleanMake
        val m = rawModel.trim()
        if (Regex("^(?:f[\\s-]*\\d{3}|bronco(?:\\s+sport)?|mustang(?:\\s+mach-?e)?|explorer|escape|expedition(?:\\s+max)?|maverick|ranger|transit)$", RegexOption.IGNORE_CASE).matches(m)) {
            return "Ford"
        }
        return ""
    }

    private fun fetchCandidatesForTarget(target: JSONObject): List<JSONObject> {
        val cond = target.optString("condition", "Any").lowercase(Locale.US)
        val pageIds = when {
            cond == "new" -> listOf(1446609)
            cond == "pre-owned" || cond == "used" || cond == "cpo" || cond == "certified pre-owned" ->
                listOf(1446611)
            else -> listOf(1446609, 1446611)
        }
        val model = target.optString("model", "").trim()
        val make = inferMakeFromModel(target.optString("make", ""), model)
        val bedLength = target.optString("bedLength", "").trim()
        val variants = expandModelVariants(make, model)
        val bedFacets = bedLengthToFacetValues(bedLength)
        val byVin = LinkedHashMap<String, JSONObject>()

        for (pid in pageIds) {
            if (bedFacets.isNotEmpty()) {
                val modelsToQuery = if (variants.isNotEmpty()) variants else listOf("")
                for (mv in modelsToQuery) {
                    for (bf in bedFacets) {
                        val fp = LinkedHashMap<String, String>()
                        fp["BedLength"] = bf
                        if (make.isNotEmpty()) fp["Make"] = make
                        if (mv.isNotEmpty()) fp["Model"] = mv
                        var totalPages = 1
                        var page = 1
                        while (page <= totalPages && page <= 12) {
                            val res = querySinglePage(pid, fp, page, facetBedLength = bedLength)
                            totalPages = res.second
                            for (v in res.first) {
                                val vin = v.optString("vin", "")
                                if (vin.isNotEmpty()) byVin[vin] = v
                            }
                            page++
                        }
                    }
                }
            }

            val modelRuns = if (make.isNotEmpty() && variants.isNotEmpty()) variants else listOf("")
            for (mv in modelRuns) {
                val params = LinkedHashMap<String, String>()
                if (make.isNotEmpty()) params["Make"] = make
                if (make.isNotEmpty() && mv.isNotEmpty()) params["Model"] = mv

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
        }
        return byVin.values.toList()
    }

    private fun querySinglePage(
        pageId: Int,
        params: Map<String, String>,
        pageNumber: Int,
        facetBedLength: String = ""
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
                parseVehicleCard(vc, facetBedLength = facetBedLength)?.let { out.add(it) }
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

    private fun extractCabStyle(text: String): String = when {
        Regex("\\b(?:super\\s*crew|crew\\s*cab|crewcab|crewmax)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text) -> "Crew Cab"
        Regex("\\b(?:super\\s*cab|extended\\s*cab|ext\\.?\\s*cab|double\\s*cab|quad\\s*cab)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text) -> "SuperCab"
        Regex("\\b(?:regular\\s*cab|reg\\.?\\s*cab|single\\s*cab|standard\\s*cab)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text) -> "Regular Cab"
        else -> ""
    }

    private fun extractBedLengthFromVehicleText(
        title: String,
        model: String,
        bodyStyle: String,
        commentsClean: String,
        lengthInches: Double,
        facetBedLength: String
    ): String {
        if (facetBedLength.isNotEmpty()) return facetBedLength
        val text = "$title | $bodyStyle | $commentsClean"
        if (Regex("\\b(?:6\\.75|6[\\s-]*3/4)\\s*(?:-|\\s)*(?:ft\\.?|foot|feet|')\\s*(?:pickup\\s*)?(?:bed|box)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
            return "6.75'"
        }
        if (Regex("\\b(?:6\\.5|6[\\s-]*1/2)\\s*(?:-|\\s)*(?:ft\\.?|foot|feet|')\\s*(?:styleside\\s+|pickup\\s+)?(?:bed|box)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
            return "6.5'"
        }
        if (Regex("\\b(?:5\\.5|5[\\s-]*1/2)\\s*(?:-|\\s)*(?:ft\\.?|foot|feet|')\\s*(?:styleside\\s+|pickup\\s+)?(?:bed|box)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
            return "5.5'"
        }
        if (Regex("\\b8(?:\\.0)?\\s*(?:-|\\s)*(?:ft\\.?|foot|feet|')\\s*(?:styleside\\s+|pickup\\s+)?(?:bed|box)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
            return "8'"
        }
        if (Regex("\\b5(?:\\.0)?\\s*(?:-|\\s)*(?:ft\\.?|foot|feet|')\\s*(?:pickup\\s*)?(?:bed|box)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
            return "5'"
        }
        if (Regex("\\b6(?:\\.0)?\\s*(?:-|\\s)*(?:ft\\.?|foot|feet|')\\s*(?:pickup\\s*)?(?:bed|box)\\b", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
            return "6'"
        }
        val isF150 = Regex("\\bf[\\s+-]*150\\b", RegexOption.IGNORE_CASE).containsMatchIn("$model $title") &&
            !title.contains("lightning", ignoreCase = true)
        if (isF150 && lengthInches > 0.0) {
            val cab = extractCabStyle("$bodyStyle $title $commentsClean")
            if (cab == "Regular Cab") {
                if (lengthInches in 207.0..212.0) return "6.5'"
                if (lengthInches in 225.0..230.0) return "8'"
            } else if (cab == "SuperCab") {
                if (lengthInches in 229.0..235.0) return "6.5'"
                if (lengthInches in 248.0..253.0) return "8'"
            }
        }
        return ""
    }

    private fun parseVehicleCard(vc: JSONObject, facetBedLength: String = ""): JSONObject? {
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

        val commentsClean = vc.optString("VehicleComments", "")
            .replace(Regex("<[^>]+>"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()
        val titleStr = vc.optString("VehicleName", "")
        val modelStr = vc.optString("VehicleModel", "")
        val bodyStyle = vc.optString("VehicleBodyStyle", vc.optString("VehicleBodyType", ""))
        val lenInches = vc.optDouble("Length", 0.0)
        val bedLength = extractBedLengthFromVehicleText(
            title = titleStr,
            model = modelStr,
            bodyStyle = bodyStyle,
            commentsClean = commentsClean,
            lengthInches = lenInches,
            facetBedLength = facetBedLength
        )
        val cabStyle = extractCabStyle("$bodyStyle $titleStr $commentsClean")

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

        val rawDt = "${vc.optString("VehicleDriveTrain", "")} $highlights $commentsClean".uppercase(Locale.US)
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
            put("title", titleStr)
            val yr = vc.optInt("VehicleYear", 0)
            if (yr > 0) put("year", yr)
            put("make", vc.optString("VehicleMake", ""))
            put("model", modelStr)
            put("trim", vc.optString("VehicleTrim", vc.optString("VehicleRuleAdjustedTrim", "")).trim())
            put("bodyStyle", bodyStyle)
            put("bedLength", bedLength)
            put("cabStyle", cabStyle)
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
        val model = target.optString("model", "").trim()
        if (model.isNotEmpty()) {
            val combinedLower = "${v.optString("model")} ${v.optString("title")}".lowercase(Locale.US)
            val modelLower = model.lowercase(Locale.US)
            if (modelLower == "bronco" && Regex("\\bbronco\\s+sport\\b").containsMatchIn(combinedLower)) return false
            if (modelLower == "mustang" && Regex("\\bmach[\\s-]*e\\b").containsMatchIn(combinedLower)) return false
            if (modelLower == "cherokee" && Regex("\\bgrand\\s+cherokee\\b").containsMatchIn(combinedLower)) return false
            if (Regex("^f[\\s-]*150$", RegexOption.IGNORE_CASE).matches(model) && combinedLower.contains("lightning")) return false

            val fMatch = Regex("^f[\\s-]*(\\d{3})$", RegexOption.IGNORE_CASE).matchEntire(model)
            if (fMatch != null) {
                val num = fMatch.groupValues[1]
                if (!Regex("\\bf[\\s+-]*$num\\b").containsMatchIn(combinedLower)) return false
            } else {
                val tokens = modelLower.replace("-", " ").split(Regex("\\s+")).filter { it.isNotEmpty() }
                val hay = combinedLower.replace("-", " ").replace("+", " ")
                if (!tokens.all { tok -> Regex("\\b${Regex.escape(tok)}\\b").containsMatchIn(hay) }) return false
            }
        }
        val trim = target.optString("trim", "").replace("®", "").replace("™", "").trim()
        if (trim.isNotEmpty()) {
            val vTrim = v.optString("trim", "").replace("®", "").replace("™", "").trim()
            val vTitle = v.optString("title", "").replace("®", "").replace("™", "").trim()
            val escaped = Regex.escape(trim).replace(Regex("[\\s\\\\-]+"), "[\\\\s-]+")
            val trimRegex = Regex("\\b$escaped\\b(?![-\\w])", RegexOption.IGNORE_CASE)
            if (!trimRegex.containsMatchIn(vTrim) && !trimRegex.containsMatchIn(vTitle)) {
                return false
            }
        }
        val targetBed = target.optString("bedLength", "").trim().removeSuffix("'")
        if (targetBed.isNotEmpty()) {
            if (v.optString("bedLength", "").trim().removeSuffix("'") != targetBed) return false
        }
        val targetCab = target.optString("cabStyle", "").trim()
        if (targetCab.isNotEmpty()) {
            if (v.optString("cabStyle", "").trim() != targetCab) return false
        }
        val cond = target.optString("condition", "Any").trim().lowercase(Locale.US)
        if (cond.isNotEmpty() && cond != "any") {
            val vc = v.optString("condition", "").lowercase(Locale.US)
            if (cond == "new" && !vc.contains("new")) return false
            if (cond == "cpo" && !vc.contains("certified")) return false
            if (cond == "pre-owned" && vc.contains("new") && !vc.contains("pre")) return false
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
            val ok = when (dt) {
                "4WD", "AWD", "4WD/AWD" -> vDt.contains("4WD") || vDt.contains("AWD")
                else -> vDt.contains(dt)
            }
            if (!ok) return false
        }

        val rawTargetColor = target.optString("exteriorColor", "").trim()
        if (rawTargetColor.isNotEmpty() && !rawTargetColor.equals("Any", ignoreCase = true)) {
            val wantedColors = rawTargetColor
                .split(Regex("[,;|/]+|\\b(?:or|and)\\b", RegexOption.IGNORE_CASE))
                .map { it.trim().lowercase(Locale.US) }
                .filter { it.isNotEmpty() && it != "any" && it != "any color" }
            if (wantedColors.isNotEmpty()) {
                val vColor = v.optString("exteriorColor", "").lowercase(Locale.US)
                if (vColor.isEmpty()) return false
                val anyColorMatches = wantedColors.any { c ->
                    when (c) {
                        "gray", "grey" -> vColor.contains("gray") || vColor.contains("grey") || vColor.contains("slate") || vColor.contains("magnetic") || vColor.contains("carbonized") || vColor.contains("charcoal")
                        "white" -> vColor.contains("white") || vColor.contains("ivory") || vColor.contains("pearl") || vColor.contains("oxford")
                        "black" -> vColor.contains("black") || vColor.contains("ebony") || vColor.contains("onyx") || vColor.contains("agate")
                        "silver" -> vColor.contains("silver") || vColor.contains("ingot") || vColor.contains("billet")
                        "blue" -> vColor.contains("blue") || vColor.contains("navy") || vColor.contains("azure") || vColor.contains("antimatter") || vColor.contains("velocity")
                        "red" -> vColor.contains("red") || vColor.contains("ruby") || vColor.contains("crimson") || vColor.contains("burgundy")
                        "brown" -> vColor.contains("brown") || vColor.contains("bronze") || vColor.contains("copper") || vColor.contains("mocha") || vColor.contains("kodiak")
                        "tan" -> vColor.contains("tan") || vColor.contains("beige") || vColor.contains("sand") || vColor.contains("dune") || vColor.contains("terrain")
                        else -> vColor.contains(c)
                    }
                }
                if (!anyColorMatches) return false
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
