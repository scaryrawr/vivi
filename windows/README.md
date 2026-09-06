# Windows application

Vivi's Windows application will use **WinUI 3 through the Windows App SDK**.
This directory owns XAML, Windows-native lifecycle and accessibility, shell
integration, Windows App SDK deployment, MSIX packaging, and native tests.

No Windows executable exists yet. The first buildable slice should use MSBuild
to invoke the root Zig graph once per architecture:

```powershell
zig build install-c-api `
  -Dtarget=x86_64-windows-msvc `
  -Dbackend-linkage=dynamic `
  --prefix <staging-directory>
```

Windows ships separate x86, x64, and ARM64 artifacts; do not combine them.
A C# host loads the resulting DLL through P/Invoke. Export decoration and
deployment details belong to the Windows packaging layer, not Zig domain code.
The minimum supported Windows release must be pinned in the Windows project
when that project is introduced.

The current Zig 0.16 toolchain cross-builds x64 Debug DLLs and ARM64
ReleaseSafe DLLs from macOS. ARM64 Debug currently fails inside Zig's
`libubsan` compilation, so that configuration must be rechecked on a native
Windows toolchain before the app target is introduced.
