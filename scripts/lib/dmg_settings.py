# dmgbuild settings for release DMG layout.

import os

app = defines["app"]
app_name = os.path.basename(app.rstrip("/"))

files = [app]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
filesystem = "HFS+"

# ((left, top), (width, height))
window_rect = ((120, 80), (680, 440))

show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"

icon_size = 96
text_size = 12
show_icon_preview = True
show_item_info = False

# Symmetric margins; shifted up/right from previous tweak.
icon_locations = {
    app_name: (190, 182),
    "Applications": (451, 182),
}
