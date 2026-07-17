@echo off
setlocal
set "ROOT=%~dp0"
set "LOG=%ROOT%guest-validation.log"

> "%LOG%" echo Guest validation started: %DATE% %TIME%
>> "%LOG%" ver
>> "%LOG%" echo PROCESSOR_ARCHITECTURE=%PROCESSOR_ARCHITECTURE%
>> "%LOG%" echo PROCESSOR_ARCHITEW6432=%PROCESSOR_ARCHITEW6432%

"%ROOT%python.exe" "%ROOT%guest_validate.py" >> "%LOG%" 2>&1
set "RESULT=%ERRORLEVEL%"
>> "%LOG%" echo EXIT_CODE=%RESULT%
type "%LOG%"
exit /b %RESULT%
