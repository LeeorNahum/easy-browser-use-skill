# File Dialogs

The [file dialog script](../scripts/answer-file-dialog.ps1) waits for a browser's Save As or Open dialog, finds it by its exact title even behind other windows, puts the path into the file name box with a window message, and presses Save or Open. It activates no window and sends no keys. `-Title` is the dialog's title as shown, `Save As` or `Open` on an English Windows. `-ProcessName` takes another browser's process name and defaults to `chrome`. It has been tried only with Chrome on an English Windows.

## Running It

Start the script as a background command, or as a separate process whose output can be read while it runs, and click only after it prints `WAITING`. If it ends before printing `WAITING`, read its result and do not click. The click can still be waiting while the dialog stays open, so run any rerun as its own command. By default it ignores a matching dialog that was already open when it started, and waits up to 15 seconds for a new one. Raise `-TimeoutSec` for a slow page. For a dialog that is already waiting, run it with `-Existing`, and no click is needed.

Where the skill's files are not on disk, fetch the script and run it in one line. Where they are, run it from the skill's folder. Both lines are PowerShell. On a machine with only Windows PowerShell 5.1, write `powershell` in place of `pwsh`:

```powershell
$s = Join-Path $env:TEMP "answer-file-dialog-$([guid]::NewGuid()).ps1"; Invoke-RestMethod 'https://raw.githubusercontent.com/LeeorNahum/easy-browser-use-skill/main/scripts/answer-file-dialog.ps1' -OutFile $s -ErrorAction Stop; pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $s -Title 'Save As' -Path 'C:\full\destination\name.ext'
pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<skill-root>\scripts\answer-file-dialog.ps1' -Title 'Open' -Path 'C:\first\file.ext|C:\second\file.ext'
```

- Inside the single quotes, write each `'` in a path as `''`. A missing or malformed argument fails before the script starts, with PowerShell's own error and no result line.
- Give Save As the full path the file should end at, starting with its drive, with its extension. The dialog can open in a folder the browser remembers from an earlier save, which is not always Downloads, so leaving out `-Path` keeps the proposed name and can save somewhere unexpected.
- Give an Open dialog the full path of the file. For several files, which may sit in different folders, separate their full paths with `|`, which no Windows path contains. A file input that takes one file takes one path.
- `-Cancel` in place of `-Path` presses Cancel.

## Results

The script prints one result line, starting with the word below, and exits with its number. `BAD_PATH`, and `ERROR` from a failed start, come before `WAITING`.

| Exit | Word | Meaning | Next |
| --- | --- | --- | --- |
| 0 | `DONE` | The dialog closed | Check that the saved file exists, which can take a moment, or that the page shows the chosen file. After `-Cancel`, nothing more |
| 1 | `ERROR` | The script itself failed | Read the message, and check whether a dialog is still open |
| 2 | `NO_DIALOG` | No matching dialog appeared in time | If the dialog is open now, run again with `-Existing`. A browser that saves without asking puts the file in its downloads folder, so look there and move it to the path. Otherwise check the title, the process name, and that the click happened |
| 3 | `AMBIGUOUS` | More than one matched, and each is left open | The script cannot pick one. Cancel them on screen through desktop control, or report it |
| 4 | `NO_BOX` | No file name box was found, and the dialog is left open | Run again with `-Existing -Cancel`, then report it |
| 5 | `NOT_SET` | The box did not take the path, or a Save As got several, and the dialog is left open | Fix `-Path` and run again with `-Existing`, or run again with `-Existing -Cancel` |
| 6 | `REJECTED` | The dialog could not use the name, and was cancelled | Fix the path, start the script again, then click again. Check what the page now holds |
| 7 | `BLOCKED` | Another box sits over the dialog, and both are left open | Look at the box on screen. Answering it can finish the save, so check for the file before running again with `-Existing` |
| 8 | `TAKEN` | The Save As path already exists, and the dialog is left open | When the old file is meant to be replaced, ask before removing it, then run again with `-Existing` and the same path. Otherwise run again with `-Existing` and a path that does not exist yet, and say which name was used |
| 9 | `OPEN` | The dialog did not close | Run again with `-Existing -Cancel`. If that also ends in `OPEN`, report it |
| 10 | `BAD_PATH` | `-Path` is not usable, so nothing was watched or touched | Fix `-Path` before the click |

## Typing A Path

When a dialog is left to desktop control, do not type the path as simulated keystrokes. Typed paths can come out with shifted and special characters changed or dropped, and keys sent after focus moves land in whatever window is in front, Enter included.
