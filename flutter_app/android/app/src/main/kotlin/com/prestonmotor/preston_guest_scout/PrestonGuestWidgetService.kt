package com.prestonmotor.preston_guest_scout

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray

class PrestonGuestWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return RecentTenGuestsFactory(applicationContext)
    }
}

class RecentTenGuestsFactory(private val context: Context) :
    RemoteViewsService.RemoteViewsFactory {

    data class GuestRow(val id: String, val name: String)

    private val items = mutableListOf<GuestRow>()

    override fun onCreate() {
        loadRecentTen()
    }

    override fun onDataSetChanged() {
        loadRecentTen()
    }

    private fun loadRecentTen() {
        items.clear()
        val prefs = context.getSharedPreferences(
            MainActivity.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        val rawJson = prefs.getString(MainActivity.KEY_RECENT_TEN_JSON, "[]") ?: "[]"
        try {
            val arr = JSONArray(rawJson)
            // Strictly enforce maximum of last 10 guests input
            val count = minOf(arr.length(), 10)
            for (i in 0 until count) {
                val obj = arr.getJSONObject(i)
                val id = obj.optString("id", "")
                val name = obj.optString("name", "")
                if (id.isNotBlank() && name.isNotBlank()) {
                    items.add(GuestRow(id, name))
                }
            }
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        items.clear()
    }

    override fun getCount(): Int = items.size

    override fun getViewAt(position: Int): RemoteViews? {
        if (position < 0 || position >= items.size) return null
        val row = items[position]
        val views = RemoteViews(context.packageName, R.layout.guest_widget_item)
        views.setTextViewText(R.id.widget_item_guest_name, row.name)

        // Fill-in intent carrying the selected guest's ID to open their vehicle list directly
        val fillInIntent = Intent().apply {
            putExtra(MainActivity.EXTRA_GUEST_ID, row.id)
            data = Uri.parse("prestonscout://guest/${Uri.encode(row.id)}")
        }
        views.setOnClickFillInIntent(R.id.widget_item_root, fillInIntent)
        return views
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
}
