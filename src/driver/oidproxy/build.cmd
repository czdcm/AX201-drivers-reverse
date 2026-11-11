@echo off
setlocal
set KITS=C:\Program Files (x86)\Windows Kits\10
set WDKV=10.0.22621.0
set SDKV=10.0.26100.0
set VC=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231
set WORK=C:\ProgramData\AX201work\driver

set PATH=%VC%\bin\Hostx64\x64;%KITS%\bin\%WDKV%\x64;%PATH%
set INCLUDE=%KITS%\Include\%WDKV%\km;%KITS%\Include\%SDKV%\shared;%KITS%\Include\%SDKV%\um;%KITS%\Include\%SDKV%\ucrt;%VC%\include
set LIB=%KITS%\Lib\%WDKV%\km\x64;%KITS%\Lib\%SDKV%\um\x64;%KITS%\Lib\%SDKV%\ucrt\x64;%VC%\lib\x64

cd /d %WORK%

echo === compiling ===
cl /nologo /c /kernel /GS- /Gz /Oy- /W3 /D_WIN64 /D_AMD64_ /DAMD64 /D_AMD64 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000000 /DNDIS680 /DPOOL_NX_OPTIN=1 /DUNICODE /D_UNICODE oidproxy.c
if errorlevel 1 goto fail

echo === linking ===
link /nologo /DRIVER /SUBSYSTEM:NATIVE /MACHINE:X64 /ENTRY:DriverEntry /NODEFAULTLIB ^
  /OUT:oidproxy.sys oidproxy.obj ^
  ntoskrnl.lib ndis.lib BufferOverflowK.lib wdmsec.lib
if errorlevel 1 goto fail

echo === built ===
dir oidproxy.sys
exit /b 0

:fail
echo BUILD_FAILED
exit /b 1
