/*
   Persisted JSON for bulk remote desktop bookmarks.

   SPDX-License-Identifier: MPL-2.0
*/

package com.freerdp.freerdpcore.custom;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

public final class RemoteDesktopConfigStore
{
	private static final String PREFS = "remote_desktop_json_config";
	private static final String KEY_JSON = "json";

	public static final String DEFAULT_JSON =
	    "{\n"
	    + "  \"bookmarks\": [\n"
	    + "    {\n"
	    + "      \"label\": \"示例桌面\",\n"
	    + "      \"hostname\": \"192.168.1.100\",\n"
	    + "      \"port\": 3389,\n"
	    + "      \"username\": \"Administrator\",\n"
	    + "      \"password\": \"\",\n"
	    + "      \"domain\": \"\"\n"
	    + "    }\n"
	    + "  ]\n"
	    + "}";

	private RemoteDesktopConfigStore()
	{
	}

	public static String loadJson(Context context)
	{
		String saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
		                  .getString(KEY_JSON, null);
		if (saved != null && !saved.trim().isEmpty())
			return saved.trim();
		return DEFAULT_JSON;
	}

	public static void saveJson(Context context, String json)
	{
		context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
		    .edit()
		    .putString(KEY_JSON, json.trim())
		    .apply();
	}

	public static boolean isValid(String json)
	{
		try
		{
			return parseBookmarkArray(json).length() > 0;
		}
		catch (Exception e)
		{
			return false;
		}
	}

	static JSONArray parseBookmarkArray(String json) throws org.json.JSONException
	{
		String trimmed = json.trim();
		if (trimmed.startsWith("["))
			return new JSONArray(trimmed);

		JSONObject root = new JSONObject(trimmed);
		if (root.has("bookmarks"))
			return root.getJSONArray("bookmarks");

		throw new org.json.JSONException("缺少 bookmarks 数组");
	}
}
