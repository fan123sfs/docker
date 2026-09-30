// SPDX-License-Identifier: BSD-3-Clause
package com.tailscale.ipn.headscale

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.work.WorkInfo
import androidx.work.WorkManager
import java.util.UUID

@Composable
fun HeadscaleConfigDialog(
    initialText: String,
    onSubmit: (String) -> Unit,
) {
  val context = LocalContext.current
  var text by remember(initialText) { mutableStateOf(initialText) }
  var error by remember { mutableStateOf<String?>(null) }
  var connecting by remember { mutableStateOf(false) }
  var workId by remember { mutableStateOf<UUID?>(null) }

  LaunchedEffect(workId) {
    val id = workId ?: return@LaunchedEffect
    WorkManager.getInstance(context).getWorkInfoByIdFlow(id).collect { info ->
      if (info == null) return@collect
      when (info.state) {
        WorkInfo.State.SUCCEEDED -> connecting = false
        WorkInfo.State.FAILED,
        WorkInfo.State.CANCELLED -> {
          connecting = false
          error =
              info.outputData.getString(HeadscaleLoginWorker.EXTRA_ERROR)
                  ?: "连接失败，请检查 login-server、auth-key 和网络"
        }
        WorkInfo.State.RUNNING,
        WorkInfo.State.ENQUEUED,
        WorkInfo.State.BLOCKED -> connecting = true
      }
    }
  }

  Dialog(
      onDismissRequest = {},
      properties =
          DialogProperties(
              dismissOnBackPress = false,
              dismissOnClickOutside = false,
              usePlatformDefaultWidth = false,
              decorFitsSystemWindows = false,
          ),
  ) {
    val view = LocalView.current
    SideEffect {
      (view.parent as? DialogWindowProvider)?.window?.let { window ->
        WindowCompat.setDecorFitsSystemWindows(window, false)
      }
    }
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
      val layoutDirection = LocalLayoutDirection.current
      val safe = WindowInsets.safeDrawing.asPaddingValues()
      val extra = 16.dp
      Column(
          modifier =
              Modifier.fillMaxSize()
                  .padding(
                      start = safe.calculateStartPadding(layoutDirection) + extra,
                      top = maxOf(safe.calculateTopPadding(), 32.dp) + extra,
                      end = safe.calculateEndPadding(layoutDirection) + extra,
                      bottom = maxOf(safe.calculateBottomPadding(), 48.dp) + extra,
                  )) {
            Text("Headscale 配置（JSON）", style = MaterialTheme.typography.headlineSmall)
            Spacer(modifier = Modifier.size(12.dp))
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
              OutlinedTextField(
                  value = text,
                  onValueChange = {
                    text = it
                    error = null
                  },
                  modifier = Modifier.fillMaxSize(),
                  label = { Text("login-server / auth-key") },
                  isError = error != null,
                  enabled = !connecting,
                  singleLine = false)
            }
            error?.let { err ->
              Spacer(modifier = Modifier.size(8.dp))
              Text(
                  text = err,
                  color = MaterialTheme.colorScheme.error,
                  style = MaterialTheme.typography.bodyMedium)
            }
            Spacer(modifier = Modifier.size(16.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically) {
                  TextButton(
                      onClick = {
                        val clip = clipboardText(context)
                        if (clip.isNullOrBlank()) {
                          error = "剪贴板为空"
                          return@TextButton
                        }
                        text = clip
                        error =
                            when (val parsed = HeadscaleConfigStore.parseResult(clip)) {
                              is HeadscaleParseResult.Ok -> null
                              is HeadscaleParseResult.Err -> parsed.message
                            }
                      },
                      enabled = !connecting) {
                        Text("粘贴")
                      }
                  Spacer(modifier = Modifier.width(8.dp))
                  Button(
                      onClick = {
                        when (val parsed = HeadscaleConfigStore.parseResult(text)) {
                          is HeadscaleParseResult.Err -> {
                            error = parsed.message
                          }
                          is HeadscaleParseResult.Ok -> {
                            error = null
                            connecting = true
                            onSubmit(text)
                            val id = HeadscaleLoginWorker.lastWorkId
                            if (id == null) {
                              connecting = false
                              error = "未能启动连接任务"
                            } else {
                              workId = id
                            }
                          }
                        }
                      },
                      enabled = !connecting) {
                        if (connecting) {
                          CircularProgressIndicator(
                              modifier = Modifier.size(18.dp),
                              strokeWidth = 2.dp,
                              color = MaterialTheme.colorScheme.onPrimary)
                          Spacer(modifier = Modifier.width(8.dp))
                          Text("连接中…")
                        } else {
                          Text("连接")
                        }
                      }
                }
          }
    }
  }
}

private fun clipboardText(context: Context): String? {
  val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
  if (clipboard == null || !clipboard.hasPrimaryClip()) {
    return null
  }
  val item = clipboard.primaryClip?.getItemAt(0) ?: return null
  return item.coerceToText(context)?.toString()?.trim()?.takeIf { it.isNotEmpty() }
}
