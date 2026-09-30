/*
   Import JSON bookmark definitions into the encrypted bookmark database.

   SPDX-License-Identifier: MPL-2.0
*/

package com.freerdp.freerdpcore.custom;

import android.content.Context;

import com.freerdp.freerdpcore.data.AppDatabase;
import com.freerdp.freerdpcore.domain.BookmarkBase;
import com.freerdp.freerdpcore.services.ManualBookmarkGateway;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

public final class RemoteDesktopConfigImporter
{
	private RemoteDesktopConfigImporter()
	{
	}

	public static List<BookmarkBase> parse(String json) throws org.json.JSONException
	{
		JSONArray array = RemoteDesktopConfigStore.parseBookmarkArray(json);
		ArrayList<BookmarkBase> out = new ArrayList<>(array.length());
		for (int i = 0; i < array.length(); i++)
		{
			JSONObject obj = array.getJSONObject(i);
			String hostname = obj.optString("hostname", "").trim();
			if (hostname.isEmpty())
				throw new org.json.JSONException("第 " + (i + 1) + " 项缺少 hostname");

			BookmarkBase bookmark = new BookmarkBase();
			bookmark.setType(BookmarkBase.TYPE_MANUAL);
			bookmark.setLabel(obj.optString("label", hostname).trim());
			bookmark.setHostname(hostname);
			bookmark.setPort(obj.optInt("port", 3389));
			bookmark.setUsername(obj.optString("username", ""));
			bookmark.setPassword(obj.optString("password", ""));
			bookmark.setDomain(obj.optString("domain", ""));
			out.add(bookmark);
		}
		if (out.isEmpty())
			throw new org.json.JSONException("bookmarks 为空");
		return out;
	}

	public static void apply(Context context, String json) throws org.json.JSONException
	{
		List<BookmarkBase> bookmarks = parse(json);
		ManualBookmarkGateway gateway =
		    new ManualBookmarkGateway(AppDatabase.getInstance(context).bookmarkDao());
		gateway.deleteAll();
		for (BookmarkBase bookmark : bookmarks)
			gateway.insert(bookmark);
		RemoteDesktopConfigStore.saveJson(context, json);
	}
}
