@echo off
setlocal EnableExtensions
set "HUB=E:\code-yan\other\docker\github"
set "MSG=E:\code-yan\other\docker\github\_commitmsg.txt"

echo merge docker-github into hub> "%MSG%"

echo [1/3] merge docker-github/* into hub
if not exist "%HUB%" mkdir "%HUB%"
for %%D in (docker-yandataai docker-yansemail docker-3391173966 docker-3388637010) do (
  echo   from %%D
  robocopy "E:\code-yan\other\docker-github\%%D" "%HUB%" /E /XD .git /XF _hub_sync.bat _commitmsg.txt /NFL /NDL /NJH /NJS /NC /NS
)

echo [2/3] hub -^> 4 mirrors
for %%D in (docker-yandataai docker-yansemail docker-3391173966 docker-3388637010) do (
  echo   %%D
  robocopy "%HUB%" "E:\code-yan\other\docker-github\%%D" /MIR /XD .git /NFL /NDL /NJH /NJS /NC /NS
  cd /d "E:\code-yan\other\docker-github\%%D"
  git add -A
  git diff --cached --quiet
  if errorlevel 1 git commit -F "%MSG%"
)

echo [3/3] push github remotes
for %%D in (docker-yandataai docker-yansemail docker-3391173966 docker-3388637010) do (
  cd /d "E:\code-yan\other\docker-github\%%D"
  git push github main
  if errorlevel 1 exit /b 1
)
exit /b 0
