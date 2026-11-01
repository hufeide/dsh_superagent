@echo off
rem Launcher for the dsh-superagent profile on Windows.
rem
rem The plugin's startup check runs `env PATH=... <cli> ...` (see src/deployment.ts
rem workerProbe). Windows has no built-in `env`, so a POSIX `env` must be on PATH.
rem Git for Windows ships one at C:\Program Files\Git\usr\bin\env.exe, so put that
rem directory first on PATH before starting dsh. This keeps the change local to the
rem profile instead of editing the machine PATH.
setlocal
set "PATH=C:\Program Files\Git\usr\bin;%PATH%"
"E:\Users\1\AppData\Local\Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd" --profile superagent %*
