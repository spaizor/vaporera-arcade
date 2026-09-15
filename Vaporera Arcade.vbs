' Lanzador sin ventana de consola para VaporeraArcade.ps1
' Vaporera Arcade
Option Explicit
Dim sh, carpeta, cmd
Set sh = CreateObject("WScript.Shell")
carpeta = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & carpeta & "VaporeraArcade.ps1"""
sh.Run cmd, 0, False
