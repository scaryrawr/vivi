# Linux application

Vivi's Linux application will target the **GNOME platform with GTK 4 and
libadwaita**. This directory owns GNOME-native lifecycle and accessibility,
GLib main-loop integration, desktop files, portals, notifications, packaging,
and native tests.

No Linux executable exists yet. The first buildable slice should use Meson to
invoke the root Zig graph as a custom target:

```sh
zig build install-c-api \
  -Dtarget=x86_64-linux-gnu \
  --prefix <staging-directory>
```

Meson may request a static archive or pass `-Dbackend-linkage=dynamic` for a
shared object. Blocking SDK work must run away from the GLib main loop.
GNOME presentation and toolkit state remain here; product and Copilot behavior
remain in the Zig backend.
