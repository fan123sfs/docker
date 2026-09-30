// SPDX-License-Identifier: BSD-3-Clause
package com.tailscale.ipn.headscale

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import com.tailscale.ipn.StartVPNWorker
import com.tailscale.ipn.UninitializedApp
import com.tailscale.ipn.util.TSLog

/**
 * 开机后自动启动：先拉起前台服务和应用界面（BOOT_COMPLETED 允许后台启 Activity / FGS），
 * 再排队连接 Headscale / VPN。仅 enqueue WorkManager 在国产机上经常被立刻杀掉。
 */
class BootCompletedReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent?) {
    val action = intent?.action ?: return
    if (action !in BOOT_ACTIONS) {
      return
    }

    val appContext = context.applicationContext
    try {
      UninitializedApp.get().startForegroundForLogin()
    } catch (e: Exception) {
      TSLog.e(TAG, "boot startForegroundForLogin: $e")
    }

    val pendingResult = goAsync()
    Handler(Looper.getMainLooper()).postDelayed(
        {
          try {
            startApp(appContext)
            connect(appContext)
          } finally {
            pendingResult.finish()
          }
        },
        START_DELAY_MS)
  }

  private fun startApp(context: Context) {
    val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
    launch.addFlags(
        Intent.FLAG_ACTIVITY_NEW_TASK or
            Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
    try {
      context.startActivity(launch)
    } catch (e: Exception) {
      TSLog.e(TAG, "boot startActivity: $e")
    }
  }

  private fun connect(context: Context) {
    if (HeadscaleConfigStore.loadConfig(context) != null) {
      HeadscaleLoginWorker.enqueue(context)
      return
    }
    val req =
        OneTimeWorkRequest.Builder(StartVPNWorker::class.java)
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag(WORK_CONNECT)
            .build()
    WorkManager.getInstance(context)
        .enqueueUniqueWork(WORK_CONNECT, ExistingWorkPolicy.REPLACE, req)
  }

  companion object {
    private const val TAG = "BootCompletedReceiver"
    private const val WORK_CONNECT = "headscale-boot-connect-vpn"
    private const val START_DELAY_MS = 2_000L
    private val BOOT_ACTIONS =
        setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
  }
}
