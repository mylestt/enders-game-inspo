@tool
extends Resource
class_name MapRegistry

# The list of hand-built arena maps, editable in the inspector. Double-click
# `map_registry.tres` in the FileSystem dock, add an element to `maps`, and drag your
# arena .tscn into its `scene` slot — that's the whole registration step (see MapListing).
#
# MapGenerator preloads map_registry.tres, so this list is what feeds the map-picker
# dropdowns, lobby validation and the server. Because it is a preloaded resource holding
# PackedScene references, the exporter tracks those scenes as dependencies and packs them
# into the dedicated-server build (a bare load("res://...") string would not be tracked and
# would ship missing). Re-export the server after adding a map — the geometry must be baked
# into the binary.

@export var maps: Array[MapListing] = []
