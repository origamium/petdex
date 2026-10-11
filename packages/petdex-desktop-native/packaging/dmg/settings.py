"""Write the installer's Finder layout without scripting a running Finder."""
import json
import os

with open(os.environ["PETDEX_PACKAGE_MANIFEST"], encoding="utf-8") as source:
    manifest = json.load(source)
layout = manifest["dmg"]

files = [os.environ["PETDEX_PACKAGED_APP"]]
symlinks = {"Applications": "/Applications"}
background = os.environ["PETDEX_DMG_BACKGROUND"]
format = "UDZO"
filesystem = "HFS+"
icon_locations = {
    "Petdex.app" if item["kind"] == "app" else item["name"]: (
        item["position"]["x"], item["position"]["y"]
    )
    for item in layout["items"]
}
# Finder's bounds include its toolbar; the manifest measures the background.
window_rect = ((100, 100), (layout["window_width"], layout["window_height"] + 52))
show_toolbar = True
show_sidebar = False
sidebar_width = 0
show_status_bar = False
show_pathbar = False
default_view = "icon-view"
arrange_by = None
icon_size = layout["icon_size"]
text_size = 13
label_pos = "bottom"
# Do not set hide_extensions on the app: it writes com.apple.FinderInfo onto
# the signed bundle, which makes codesign --verify --strict reject the copy.
