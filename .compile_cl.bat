@echo off
call "E:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cl /nologo /c /EHsc /MD /std:c++17 /utf-8 /I "D:\myProject\zig\zui\vendor\skia" %*
