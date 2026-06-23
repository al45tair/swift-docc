Building DocC on Windows with SwiftPM
=====================================

Building DocC on non-Windows platforms should in most cases be a
straightforward case of running

```shell
$ swift build
```

from within the `swift-docc` directory.

On Windows, however, we presently need a couple of additional steps.
First, we need to install `pkg-config`, as it doesn't exist on Windows
out of the box; we can do that with

```cmd
C:\Users\swifty>winget install bloodrock.pkg-config-lite
```

We also need to grab a copy of the zlib source code from
[zlib.net](https://zlib.net), then to build that; you'll want to do this
in a Visual Studio Developer Command Prompt:

```cmd
C:\Users\swifty>curl -L -O https://www.zlib.net/zlib132.zip
...

C:\Users\swifty>tar -xf zlib132.zip

C:\Users\swifty>cd zlib-1.3.2

C:\Users\swifty>nmake -f win32/Makefile.msc
...
```

Having built that, we need to make a `pkg-config` file for it, like this:

```
Name: zlib
Version: 1.3.2
Description: zlib compression library
Libs: -LC:/Users/swifty/zlib-1.3.2 -lzlib
Cflags: -IC:/Users/swifty/zlib-1.3.2
```

You can see where to install the file by doing

```
C:\Users\swifty>pkg-config --variable pc_path pkg-config
C:\Users\swifty\AppData\Local\Microsoft\WinGet\Links\lib/pkgconfig;C:\Users\swifty\AppData\Local\Microsoft\WinGet\Links\share/pkgconfig
```

In the above example, we'd save it to
`C:\Users\swifty\AppData\Local\Microsoft\WinGet\Links\lib\pkgconfig\zlib.pc`.
You may need to create that directory first with

```cmd
C:\Users\swifty>mkdir C:\Users\swifty\AppData\Local\Microsoft\WinGet\Links\lib\pkgconfig
```

Finally, you can go to the `swift-docc` directory and build with

```cmd
C:\Users\swifty\swift-docc>swift build --pkg-config-path C:\Users\swifty\AppData\Local\Microsoft\WinGet\Links\lib\pkgconfig
```
