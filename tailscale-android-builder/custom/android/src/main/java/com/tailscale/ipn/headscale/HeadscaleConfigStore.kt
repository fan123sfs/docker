// SPDX-License-Identifier: BSD-3-Clause
package com.tailscale.ipn.headscale

import android.content.Context
import org.json.JSONObject

data class HeadscaleConfig(val loginServer: String, val authKey: String)

sealed class HeadscaleParseResult {
  data class Ok(val config: HeadscaleConfig) : HeadscaleParseResult()

  data class Err(val message: String) : HeadscaleParseResult()
}

object HeadscaleConfigStore {
  private const val PREFS = "headscale_config"
  private const val KEY_JSON = "json"

  val DEFAULT_JSON =
      """
      {
        "login-server": "https://headscale.example.com",
        "auth-key": ""
      }
      """.trimIndent()

  fun loadJson(context: Context): String {
    val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    return prefs.getString(KEY_JSON, null)?.takeIf { it.isNotBlank() } ?: DEFAULT_JSON
  }

  fun saveJson(context: Context, json: String) {
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_JSON, json).apply()
  }

  fun loadConfig(context: Context): HeadscaleConfig? = parse(loadJson(context))

  fun parse(json: String): HeadscaleConfig? =
      when (val result = parseResult(json)) {
        is HeadscaleParseResult.Ok -> result.config
        is HeadscaleParseResult.Err -> null
      }

  fun parseResult(json: String): HeadscaleParseResult {
    val normalized = normalizeJson(json)
    if (normalized.isBlank()) {
      return HeadscaleParseResult.Err("请输入 JSON 配置")
    }
    return try {
      val obj = JSONObject(normalized)
      val loginServer =
          sequenceOf("login-server", "login_server", "loginServer")
              .map { obj.optString(it) }
              .firstOrNull { it.isNotBlank() }
              ?.trim()
      if (loginServer == null) {
        return HeadscaleParseResult.Err("缺少 login-server")
      }
      val authKey =
          sequenceOf("auth-key", "auth_key", "authKey")
              .map { obj.optString(it) }
              .firstOrNull { it.isNotBlank() }
              ?.trim()
      if (authKey == null) {
        return HeadscaleParseResult.Err("缺少 auth-key")
      }
      HeadscaleParseResult.Ok(HeadscaleConfig(loginServer, authKey))
    } catch (_: Exception) {
      HeadscaleParseResult.Err("JSON 格式无效，请检查引号、逗号和括号")
    }
  }

  private fun normalizeJson(json: String): String {
    return json.trim()
        .trim('\uFEFF')
        .replace('\u201C', '"')
        .replace('\u201D', '"')
        .replace('\u2018', '"')
        .replace('\u2019', '"')
  }
}
