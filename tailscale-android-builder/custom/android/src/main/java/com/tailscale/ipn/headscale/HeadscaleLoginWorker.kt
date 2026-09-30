// SPDX-License-Identifier: BSD-3-Clause
package com.tailscale.ipn.headscale

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.tailscale.ipn.App
import com.tailscale.ipn.ui.localapi.Client
import com.tailscale.ipn.ui.model.Ipn
import com.tailscale.ipn.ui.notifier.Notifier
import com.tailscale.ipn.util.TSLog
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay

/** Headscale / 自建 control：用 login-server + auth-key 静默登录并拉起 VPN。 */
class HeadscaleLoginWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

  override suspend fun doWork(): Result {
    val controlURL = inputData.getString(EXTRA_CONTROL_URL)
    val authKey = inputData.getString(EXTRA_AUTH_KEY)
    if (controlURL.isNullOrBlank() || authKey.isNullOrBlank()) {
      val cfg = HeadscaleConfigStore.loadConfig(applicationContext)
      if (cfg == null) {
        TSLog.e(TAG, "missing headscale config")
        return fail("缺少 Headscale 配置")
      }
      return login(cfg.loginServer, cfg.authKey)
    }
    return login(controlURL, authKey)
  }

  private suspend fun login(controlURL: String, authKey: String): Result {
    return try {
      performLogin(controlURL, authKey)
      waitUntilLoggedIn()
      Result.success()
    } catch (e: Exception) {
      TSLog.e(TAG, "headscale login failed: $e")
      if (isTransient(e) && runAttemptCount < 5) {
        Result.retry()
      } else {
        fail(userMessage(e))
      }
    }
  }

  private suspend fun performLogin(controlURL: String, authKey: String) {
    val app = App.get()
    app.startForegroundForLogin()

    val client = Client(app.applicationScope)
    val maskedPrefs =
        Ipn.MaskedPrefs().apply {
          ControlURL = controlURL
          LoggedOut = false
        }

    val prefs = await<Ipn.Prefs> { client.editPrefs(maskedPrefs, it) }.getOrThrow()
    prefs.WantRunning = true

    val opts = Ipn.Options(UpdatePrefs = prefs, AuthKey = authKey)
    await<Unit> { client.start(opts, it) }.getOrThrow()
    await<Unit> { client.startLoginInteractive(it) }.getOrThrow()
    app.startVPN()
  }

  private suspend fun waitUntilLoggedIn() {
    val urlBefore = Notifier.browseToURL.value
    val deadline = System.currentTimeMillis() + LOGIN_TIMEOUT_MS
    while (System.currentTimeMillis() < deadline) {
      when (Notifier.state.value) {
        Ipn.State.Running,
        Ipn.State.NeedsMachineAuth -> return
        else -> {}
      }
      val url = Notifier.browseToURL.value
      if (!url.isNullOrBlank() && url != urlBefore) {
        throw IllegalStateException("auth-key 无效，服务器要求浏览器登录")
      }
      delay(400)
    }
    when (Notifier.state.value) {
      Ipn.State.Running,
      Ipn.State.NeedsMachineAuth -> return
      else -> throw IllegalStateException("连接超时，请检查 login-server、auth-key 和网络")
    }
  }

  private suspend fun <T> await(call: ((kotlin.Result<T>) -> Unit) -> Unit): kotlin.Result<T> {
    val result = CompletableDeferred<kotlin.Result<T>>()
    call { result.complete(it) }
    return result.await()
  }

  private fun fail(message: String): Result {
    return Result.failure(Data.Builder().putString(EXTRA_ERROR, message.take(1000)).build())
  }

  private fun isTransient(e: Exception): Boolean {
    val message = e.message.orEmpty()
    return message.contains("Unable to resolve host", ignoreCase = true) ||
        message.contains("failed to connect", ignoreCase = true) ||
        message.contains("timeout", ignoreCase = true) ||
        message.contains("Network is unreachable", ignoreCase = true) ||
        message.contains("连接超时")
  }

  private fun userMessage(e: Exception): String {
    val message = e.message?.trim().orEmpty()
    return when {
      message.isEmpty() -> "连接失败"
      message.contains("Unable to resolve host", ignoreCase = true) ->
          "无法解析服务器地址，请检查 login-server"
      message.contains("failed to connect", ignoreCase = true) ->
          "无法连接到服务器，请检查 login-server 和网络"
      message.contains("timeout", ignoreCase = true) -> message
      message.contains("auth-key", ignoreCase = true) -> message
      else -> "连接失败：$message"
    }
  }

  companion object {
    const val TAG = "HeadscaleLoginWorker"
    const val WORK_NAME = "headscale-login"
    const val EXTRA_CONTROL_URL = "control_url"
    const val EXTRA_AUTH_KEY = "auth_key"
    const val EXTRA_ERROR = "error"
    private const val LOGIN_TIMEOUT_MS = 40_000L

    @Volatile var lastWorkId: UUID? = null
      private set

    fun enqueue(context: Context, controlURL: String? = null, authKey: String? = null): UUID {
      val builder = Data.Builder()
      if (!controlURL.isNullOrBlank()) {
        builder.putString(EXTRA_CONTROL_URL, controlURL)
      }
      if (!authKey.isNullOrBlank()) {
        builder.putString(EXTRA_AUTH_KEY, authKey)
      }
      val req =
          OneTimeWorkRequest.Builder(HeadscaleLoginWorker::class.java)
              .setInputData(builder.build())
              .setConstraints(
                  Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
              .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
              .addTag(WORK_NAME)
              .build()
      lastWorkId = req.id
      WorkManager.getInstance(context)
          .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.REPLACE, req)
      return req.id
    }
  }
}
