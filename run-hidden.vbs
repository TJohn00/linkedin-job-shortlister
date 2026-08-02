' ============================================================
'  run-hidden.vbs
'  Launches run-pipeline.bat with NO console window.
'
'  Why this exists:
'  Task Scheduler running a .bat directly spawns a console window that
'  takes focus, which interrupts whatever you are doing - every hour.
'
'  Hiding the window does NOT make the task non-interactive. The task
'  still runs under LogonType Interactive in your logged-on session, so
'  BurntToast toasts render exactly as before. "Interactive session" and
'  "visible window" are different things; only the first one matters for
'  notifications.
'
'  Window style 0 = hidden. bWaitOnReturn = True so the task's
'  LastTaskResult reflects the pipeline's real exit code instead of
'  always reporting 0.
' ============================================================

Option Explicit

Dim fso, shell, here, bat, rc

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
bat  = fso.BuildPath(here, "run-pipeline.bat")

If Not fso.FileExists(bat) Then
    WScript.Quit 2
End If

' Run hidden, wait for completion, propagate the exit code.
rc = shell.Run("cmd /c """ & bat & """", 0, True)

WScript.Quit rc
