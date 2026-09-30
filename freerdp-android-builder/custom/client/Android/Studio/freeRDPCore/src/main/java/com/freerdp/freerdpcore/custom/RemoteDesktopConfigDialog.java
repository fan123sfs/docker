/*
   Dialog to edit JSON bulk bookmark configuration.

   SPDX-License-Identifier: MPL-2.0
*/

package com.freerdp.freerdpcore.custom;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.text.InputType;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.Toast;

import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;

import com.freerdp.freerdpcore.R;
import com.freerdp.freerdpcore.presentation.HomeViewModel;

public final class RemoteDesktopConfigDialog
{
	private RemoteDesktopConfigDialog()
	{
	}

	public static void show(AppCompatActivity activity, HomeViewModel viewModel)
	{
		EditText editor = new EditText(activity);
		editor.setInputType(
		    InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
		editor.setMinLines(10);
		editor.setHorizontallyScrolling(false);
		editor.setText(RemoteDesktopConfigStore.loadJson(activity));

		int pad = (int)(16 * activity.getResources().getDisplayMetrics().density);
		LinearLayout wrap = new LinearLayout(activity);
		wrap.setOrientation(LinearLayout.VERTICAL);
		wrap.setPadding(pad, pad / 2, pad, 0);
		wrap.addView(editor);

		AlertDialog dialog =
		    new AlertDialog.Builder(activity)
		        .setTitle(R.string.menu_json_bookmarks)
		        .setView(wrap)
		        .setNeutralButton(R.string.json_bookmarks_paste, null)
		        .setNegativeButton(R.string.cancel, null)
		        .setPositiveButton(R.string.json_bookmarks_save, null)
		        .create();

		dialog.setOnShowListener(unused -> {
			dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> pasteClipboard(activity, editor));
			dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
				String json = editor.getText().toString();
				if (!RemoteDesktopConfigStore.isValid(json))
				{
					Toast.makeText(activity, R.string.json_bookmarks_invalid, Toast.LENGTH_LONG).show();
					return;
				}
				viewModel.applyJsonConfig(json, ok -> activity.runOnUiThread(() -> {
					if (ok)
					{
						Toast.makeText(activity, R.string.json_bookmarks_applied, Toast.LENGTH_SHORT).show();
						dialog.dismiss();
					}
					else
					{
						Toast.makeText(activity, R.string.json_bookmarks_failed, Toast.LENGTH_LONG).show();
					}
				}));
			});
		});

		dialog.show();
	}

	private static void pasteClipboard(AppCompatActivity activity, EditText editor)
	{
		ClipboardManager clipboard = (ClipboardManager)activity.getSystemService(Context.CLIPBOARD_SERVICE);
		CharSequence text = null;
		if (clipboard != null && clipboard.hasPrimaryClip())
		{
			ClipData clip = clipboard.getPrimaryClip();
			if (clip != null && clip.getItemCount() > 0)
				text = clip.getItemAt(0).coerceToText(activity);
		}
		if (text == null || text.length() == 0)
		{
			Toast.makeText(activity, R.string.json_bookmarks_clipboard_empty, Toast.LENGTH_SHORT).show();
			return;
		}
		editor.setText(text);
		editor.setSelection(editor.getText().length());
	}
}
