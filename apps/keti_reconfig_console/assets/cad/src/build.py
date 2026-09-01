#!/usr/bin/env python3
"""Regenerate ../vehicle_cad.html (the WebView asset) from the scene sources.

Standalone artifact = full HTML chrome; the app asset sets window.EMBED so Flutter's
own header/rails/shell-slider draw on top and the scene shows only the 3D + labels.
Run:  python3 build.py
"""
import io, os
HERE = os.path.dirname(os.path.abspath(__file__))
R = lambda p: io.open(os.path.join(HERE, p), encoding="utf-8").read()
three = R("three.min.js"); orbit = R("OrbitControls.js")
body  = R("scene_body.html").replace("/*__SCENE__*/", R("scene.js"))
libs  = "<script>%s</script>\n<script>%s</script>\n" % (three, orbit)
out = os.path.join(HERE, "..", "vehicle_cad.html")   # the flutter asset (EMBED)
io.open(out, "w", encoding="utf-8").write(libs + "<script>window.EMBED=true;</script>\n" + body)
# a standalone copy with full chrome, handy for previewing the scene in a browser
io.open(os.path.join(HERE, "vehicle_cad_standalone.html"), "w", encoding="utf-8").write(libs + body)
print("built", out)
