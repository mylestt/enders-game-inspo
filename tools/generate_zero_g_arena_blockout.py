"""Generate a Blender-ready GLB blockout for a fast enclosed zero-G arena.

The generator intentionally uses only Python's standard library plus Pillow (for the
preview), so the GLB does not depend on Blender or a third-party glTF package.
"""

from __future__ import annotations

import json
import math
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "artifacts"
GLB_PATH = OUTPUT_DIR / "zero_g_reactor_arena_blockout.glb"
PREVIEW_PATH = OUTPUT_DIR / "zero_g_reactor_arena_preview.png"


MATERIALS = {
    "Hull": (0.12, 0.16, 0.22, 1.0),
    "Structure": (0.25, 0.32, 0.40, 1.0),
    "Core": (0.62, 0.67, 0.72, 1.0),
    "RouteCyan": (0.02, 0.62, 0.78, 1.0),
    "RouteOrange": (0.95, 0.34, 0.06, 1.0),
    "Recovery": (0.18, 0.72, 0.42, 1.0),
    "SpawnA": (0.08, 0.32, 0.95, 1.0),
    "SpawnB": (0.95, 0.18, 0.08, 1.0),
    "Objective": (0.92, 0.72, 0.08, 1.0),
}


def normalize(v: tuple[float, float, float]) -> tuple[float, float, float]:
    length = math.sqrt(sum(component * component for component in v))
    return tuple(component / length for component in v)


def cross(
    a: tuple[float, float, float],
    b: tuple[float, float, float],
) -> tuple[float, float, float]:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def quat_axis_angle(
    axis: tuple[float, float, float],
    angle: float,
) -> tuple[float, float, float, float]:
    axis = normalize(axis)
    half = angle * 0.5
    sine = math.sin(half)
    return axis[0] * sine, axis[1] * sine, axis[2] * sine, math.cos(half)


def quat_mul(
    a: tuple[float, float, float, float],
    b: tuple[float, float, float, float],
) -> tuple[float, float, float, float]:
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def rotate_vector(
    q: tuple[float, float, float, float],
    v: tuple[float, float, float],
) -> tuple[float, float, float]:
    qv = q[0], q[1], q[2]
    uv = cross(qv, v)
    uuv = cross(qv, uv)
    return tuple(
        v[i] + 2.0 * (q[3] * uv[i] + uuv[i])
        for i in range(3)
    )


def box_geometry() -> tuple[list[float], list[float], list[int]]:
    faces = [
        ((1, 0, 0), [(0.5, -0.5, -0.5), (0.5, 0.5, -0.5), (0.5, 0.5, 0.5), (0.5, -0.5, 0.5)]),
        ((-1, 0, 0), [(-0.5, -0.5, 0.5), (-0.5, 0.5, 0.5), (-0.5, 0.5, -0.5), (-0.5, -0.5, -0.5)]),
        ((0, 1, 0), [(-0.5, 0.5, -0.5), (-0.5, 0.5, 0.5), (0.5, 0.5, 0.5), (0.5, 0.5, -0.5)]),
        ((0, -1, 0), [(-0.5, -0.5, 0.5), (-0.5, -0.5, -0.5), (0.5, -0.5, -0.5), (0.5, -0.5, 0.5)]),
        ((0, 0, 1), [(-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5), (-0.5, 0.5, 0.5)]),
        ((0, 0, -1), [(0.5, -0.5, -0.5), (-0.5, -0.5, -0.5), (-0.5, 0.5, -0.5), (0.5, 0.5, -0.5)]),
    ]
    positions: list[float] = []
    normals: list[float] = []
    indices: list[int] = []
    for normal, vertices in faces:
        start = len(positions) // 3
        for vertex in vertices:
            positions.extend(vertex)
            normals.extend(normal)
        indices.extend((start, start + 1, start + 2, start, start + 2, start + 3))
    return positions, normals, indices


def prism_geometry(sides: int = 12) -> tuple[list[float], list[float], list[int]]:
    positions: list[float] = []
    normals: list[float] = []
    indices: list[int] = []

    for y, normal_y, reverse in ((0.5, 1.0, False), (-0.5, -1.0, True)):
        center = len(positions) // 3
        positions.extend((0.0, y, 0.0))
        normals.extend((0.0, normal_y, 0.0))
        rim_start = len(positions) // 3
        for i in range(sides):
            angle = 2.0 * math.pi * i / sides
            positions.extend((math.cos(angle), y, math.sin(angle)))
            normals.extend((0.0, normal_y, 0.0))
        for i in range(sides):
            a = rim_start + i
            b = rim_start + (i + 1) % sides
            indices.extend((center, b, a) if reverse else (center, a, b))

    for i in range(sides):
        angle_a = 2.0 * math.pi * i / sides
        angle_b = 2.0 * math.pi * (i + 1) / sides
        normal_angle = (angle_a + angle_b) * 0.5
        normal = (math.cos(normal_angle), 0.0, math.sin(normal_angle))
        start = len(positions) // 3
        for x, y, z in (
            (math.cos(angle_a), -0.5, math.sin(angle_a)),
            (math.cos(angle_b), -0.5, math.sin(angle_b)),
            (math.cos(angle_b), 0.5, math.sin(angle_b)),
            (math.cos(angle_a), 0.5, math.sin(angle_a)),
        ):
            positions.extend((x, y, z))
            normals.extend(normal)
        indices.extend((start, start + 1, start + 2, start, start + 2, start + 3))
    return positions, normals, indices


class GlbBuilder:
    def __init__(self) -> None:
        self.binary = bytearray()
        self.buffer_views: list[dict] = []
        self.accessors: list[dict] = []
        self.meshes: list[dict] = []
        self.nodes: list[dict] = []
        self.materials: list[dict] = []
        self.material_index: dict[str, int] = {}
        self.mesh_index: dict[tuple[str, str], int] = {}
        self.groups: dict[str, list[int]] = {}
        self.preview_objects: list[dict] = []

    def add_blob(self, payload: bytes, target: int) -> int:
        while len(self.binary) % 4:
            self.binary.append(0)
        offset = len(self.binary)
        self.binary.extend(payload)
        view = {
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": len(payload),
            "target": target,
        }
        self.buffer_views.append(view)
        return len(self.buffer_views) - 1

    def add_accessor(
        self,
        view: int,
        component_type: int,
        count: int,
        accessor_type: str,
        minimum: list[float] | None = None,
        maximum: list[float] | None = None,
    ) -> int:
        accessor = {
            "bufferView": view,
            "componentType": component_type,
            "count": count,
            "type": accessor_type,
        }
        if minimum is not None:
            accessor["min"] = minimum
        if maximum is not None:
            accessor["max"] = maximum
        self.accessors.append(accessor)
        return len(self.accessors) - 1

    def add_materials(self) -> None:
        for name, color in MATERIALS.items():
            emissive = [0.0, 0.0, 0.0]
            if name in {"RouteCyan", "RouteOrange", "SpawnA", "SpawnB", "Objective"}:
                emissive = [channel * 0.12 for channel in color[:3]]
            material = {
                "name": name,
                "doubleSided": True,
                "pbrMetallicRoughness": {
                    "baseColorFactor": list(color),
                    "metallicFactor": 0.08 if name != "Core" else 0.35,
                    "roughnessFactor": 0.78,
                },
                "emissiveFactor": emissive,
            }
            self.material_index[name] = len(self.materials)
            self.materials.append(material)

    def add_geometry(self, kind: str, geometry: tuple[list[float], list[float], list[int]]) -> None:
        positions, normals, indices = geometry
        position_view = self.add_blob(struct.pack(f"<{len(positions)}f", *positions), 34962)
        normal_view = self.add_blob(struct.pack(f"<{len(normals)}f", *normals), 34962)
        index_view = self.add_blob(struct.pack(f"<{len(indices)}H", *indices), 34963)
        grouped_positions = list(zip(positions[0::3], positions[1::3], positions[2::3]))
        minimum = [min(values) for values in zip(*grouped_positions)]
        maximum = [max(values) for values in zip(*grouped_positions)]
        position_accessor = self.add_accessor(
            position_view,
            5126,
            len(positions) // 3,
            "VEC3",
            minimum,
            maximum,
        )
        normal_accessor = self.add_accessor(normal_view, 5126, len(normals) // 3, "VEC3")
        index_accessor = self.add_accessor(index_view, 5123, len(indices), "SCALAR")
        for material_name in MATERIALS:
            mesh = {
                "name": f"{kind}_{material_name}",
                "primitives": [{
                    "attributes": {
                        "POSITION": position_accessor,
                        "NORMAL": normal_accessor,
                    },
                    "indices": index_accessor,
                    "material": self.material_index[material_name],
                    "mode": 4,
                }],
            }
            self.mesh_index[(kind, material_name)] = len(self.meshes)
            self.meshes.append(mesh)

    def add_object(
        self,
        group: str,
        name: str,
        material: str,
        translation: tuple[float, float, float],
        scale: tuple[float, float, float],
        rotation: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 1.0),
        kind: str = "Box",
        extras: dict | None = None,
    ) -> None:
        node = {
            "name": name,
            "mesh": self.mesh_index[(kind, material)],
            "translation": list(translation),
            "rotation": list(rotation),
            "scale": list(scale),
            "extras": extras or {"blockout_group": group},
        }
        index = len(self.nodes)
        self.nodes.append(node)
        self.groups.setdefault(group, []).append(index)
        self.preview_objects.append({
            "name": name,
            "material": material,
            "translation": translation,
            "scale": scale,
            "rotation": rotation,
            "kind": kind,
        })

    def add_marker(
        self,
        group: str,
        name: str,
        translation: tuple[float, float, float],
        extras: dict,
    ) -> None:
        index = len(self.nodes)
        self.nodes.append({
            "name": name,
            "translation": list(translation),
            "extras": extras,
        })
        self.groups.setdefault(group, []).append(index)

    def finish_scene(self) -> dict:
        group_nodes: list[int] = []
        for group_name, children in self.groups.items():
            index = len(self.nodes)
            self.nodes.append({
                "name": group_name,
                "children": children,
                "extras": {"purpose": "editable_blockout_group"},
            })
            group_nodes.append(index)
        root_index = len(self.nodes)
        self.nodes.append({
            "name": "ZERO_G_REACTOR_ARENA_BLOCKOUT",
            "children": group_nodes,
            "extras": {
                "units": "meters",
                "design": "enclosed zero-G arena with interrupted perimeter and central route crossings",
            },
        })
        return {
            "asset": {
                "version": "2.0",
                "generator": "Codex zero-G reactor arena generator",
                "copyright": "Generated for the enders-game-inspo project",
            },
            "scene": 0,
            "scenes": [{"name": "Zero-G Reactor Arena", "nodes": [root_index]}],
            "nodes": self.nodes,
            "meshes": self.meshes,
            "materials": self.materials,
            "accessors": self.accessors,
            "bufferViews": self.buffer_views,
            "buffers": [{"byteLength": len(self.binary)}],
            "extras": {
                "design_notes": [
                    "Outer hull is closed but segmented by inward ribs to prevent endless perimeter laps.",
                    "Three paired catcher-fin routes pass through the porous reactor at different heights.",
                    "Spawn bays sit on the floor and have two lateral exits around a central blocker.",
                    "Green shelves are recovery surfaces, not intended to be the fastest route.",
                ]
            },
        }

    def write(self, gltf: dict) -> None:
        while len(self.binary) % 4:
            self.binary.append(0)
        gltf["buffers"][0]["byteLength"] = len(self.binary)
        json_bytes = json.dumps(gltf, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        while len(json_bytes) % 4:
            json_bytes += b" "
        total_length = 12 + 8 + len(json_bytes) + 8 + len(self.binary)
        header = struct.pack("<4sII", b"glTF", 2, total_length)
        json_chunk = struct.pack("<I4s", len(json_bytes), b"JSON") + json_bytes
        binary_chunk = struct.pack("<I4s", len(self.binary), b"BIN\0") + self.binary
        GLB_PATH.write_bytes(header + json_chunk + binary_chunk)


def build_arena() -> GlbBuilder:
    builder = GlbBuilder()
    builder.add_materials()
    builder.add_geometry("Box", box_geometry())
    builder.add_geometry("Prism12", prism_geometry())

    # Closed 60 m diameter, 40 m tall dodecagonal chamber.
    builder.add_object(
        "01_HULL",
        "Hull_Floor",
        "Hull",
        (0.0, -20.5, 0.0),
        (30.0, 1.0, 30.0),
        kind="Prism12",
        extras={"role": "closed_boundary", "playable_surface": True},
    )
    builder.add_object(
        "01_HULL",
        "Hull_Ceiling",
        "Hull",
        (0.0, 20.5, 0.0),
        (30.0, 1.0, 30.0),
        kind="Prism12",
        extras={"role": "closed_boundary", "playable_surface": True},
    )

    wall_radius = 29.4
    wall_length = 2.0 * wall_radius * math.tan(math.pi / 12.0) + 0.5
    for i in range(12):
        theta = 2.0 * math.pi * i / 12.0
        yaw = math.pi * 0.5 - theta
        builder.add_object(
            "01_HULL",
            f"Hull_Wall_{i + 1:02d}",
            "Hull",
            (wall_radius * math.cos(theta), 0.0, wall_radius * math.sin(theta)),
            (wall_length, 40.0, 1.2),
            quat_axis_angle((0.0, 1.0, 0.0), yaw),
            extras={"role": "closed_boundary", "sector": i + 1},
        )

    # Alternating ribs break continuous wall-running without closing the central volume.
    for i in range(12):
        theta = 2.0 * math.pi * (i + 0.5) / 12.0
        yaw = math.pi * 0.5 - theta
        y = 4.5 if i % 2 == 0 else -4.5
        builder.add_object(
            "02_PERIMETER_BAFFLES",
            f"Perimeter_Rib_{i + 1:02d}",
            "Structure",
            (26.5 * math.cos(theta), y, 26.5 * math.sin(theta)),
            (1.3, 27.0, 6.0),
            quat_axis_angle((0.0, 1.0, 0.0), yaw),
            extras={"role": "anti_orbit_baffle", "redirects_toward_center": True},
        )

    # Porous 16 m cube reactor: twelve edge beams, completely open through the middle.
    beam = 1.2
    extent = 8.0
    for y in (-extent, extent):
        for z in (-extent, extent):
            builder.add_object(
                "03_CENTRAL_REACTOR",
                f"Core_Edge_X_y{y:+.0f}_z{z:+.0f}",
                "Core",
                (0.0, y, z),
                (16.0, beam, beam),
                extras={"role": "grapple_anchor", "route_landmark": True},
            )
    for x in (-extent, extent):
        for z in (-extent, extent):
            builder.add_object(
                "03_CENTRAL_REACTOR",
                f"Core_Edge_Y_x{x:+.0f}_z{z:+.0f}",
                "Core",
                (x, 0.0, z),
                (beam, 16.0, beam),
                extras={"role": "grapple_anchor", "route_landmark": True},
            )
    for x in (-extent, extent):
        for y in (-extent, extent):
            builder.add_object(
                "03_CENTRAL_REACTOR",
                f"Core_Edge_Z_x{x:+.0f}_y{y:+.0f}",
                "Core",
                (x, y, 0.0),
                (beam, beam, 16.0),
                extras={"role": "grapple_anchor", "route_landmark": True},
            )

    # A small objective frame marks the central crossing without filling it.
    for x in (-3.5, 3.5):
        builder.add_object(
            "03_CENTRAL_REACTOR",
            f"Objective_Post_{'L' if x < 0 else 'R'}",
            "Objective",
            (x, 0.0, 0.0),
            (0.55, 7.0, 0.55),
            extras={"role": "central_objective_landmark"},
        )
    for y in (-3.5, 3.5):
        builder.add_object(
            "03_CENTRAL_REACTOR",
            f"Objective_Crossbar_{'Low' if y < 0 else 'High'}",
            "Objective",
            (0.0, y, 0.0),
            (7.0, 0.55, 0.55),
            extras={"role": "central_objective_landmark"},
        )

    # Three paired routes meet through the reactor at separate heights.
    route_heights = (0.0, 7.0, -7.0, 0.0, 7.0, -7.0)
    route_tilts = (8.0, -10.0, 10.0, -8.0, 10.0, -10.0)
    for i in range(6):
        theta = 2.0 * math.pi * i / 6.0
        yaw = math.pi - theta
        tilt = math.radians(route_tilts[i])
        rotation = quat_mul(
            quat_axis_angle((0.0, 1.0, 0.0), yaw),
            quat_axis_angle((0.0, 0.0, 1.0), tilt),
        )
        material = "RouteCyan" if i % 2 == 0 else "RouteOrange"
        builder.add_object(
            "04_CATCHER_ROUTES",
            f"Catcher_Fin_{i + 1:02d}",
            material,
            (18.0 * math.cos(theta), route_heights[i], 18.0 * math.sin(theta)),
            (17.5, 0.65, 7.5),
            rotation,
            extras={
                "role": "high_speed_catcher",
                "paired_route": (i % 3) + 1,
                "intended_risk": "fast_and_exposed",
            },
        )

    # Recovery shelves are visible and useful, but short enough not to form an outer loop.
    for i, theta_degrees in enumerate((45.0, 135.0, 225.0, 315.0)):
        theta = math.radians(theta_degrees)
        yaw = math.pi * 0.5 - theta
        y = 11.0 if i % 2 == 0 else -11.0
        builder.add_object(
            "05_RECOVERY_BAYS",
            f"Recovery_Shelf_{i + 1:02d}",
            "Recovery",
            (25.5 * math.cos(theta), y, 25.5 * math.sin(theta)),
            (7.0, 0.6, 5.5),
            quat_axis_angle((0.0, 1.0, 0.0), yaw),
            extras={"role": "recovery_surface", "intended_risk": "safe_but_slow"},
        )

    # Two protected floor spawn bays. A center front blocker creates left/right exits.
    for team, x, material in (("A", -23.0, "SpawnA"), ("B", 23.0, "SpawnB")):
        inward_sign = 1.0 if x < 0.0 else -1.0
        rear_x = x - inward_sign * 4.0
        front_x = x + inward_sign * 4.0
        builder.add_object(
            "06_SPAWN_BAYS",
            f"SpawnBay_{team}_Rear",
            material,
            (rear_x, -16.5, 0.0),
            (1.0, 7.0, 12.0),
            extras={"role": "spawn_cover", "team": team},
        )
        for side in (-1.0, 1.0):
            builder.add_object(
                "06_SPAWN_BAYS",
                f"SpawnBay_{team}_Side_{'L' if side < 0 else 'R'}",
                material,
                (x, -16.5, side * 6.0),
                (8.0, 7.0, 0.8),
                extras={"role": "spawn_cover", "team": team},
            )
        builder.add_object(
            "06_SPAWN_BAYS",
            f"SpawnBay_{team}_Front_Blocker",
            material,
            (front_x, -16.5, 0.0),
            (0.9, 7.0, 4.0),
            extras={"role": "spawn_sightline_blocker", "team": team, "exits": 2},
        )

    builder.add_marker(
        "07_MARKERS",
        "spawn",
        (-23.0, -18.9, 0.0),
        {"marker_type": "spawn", "team": "A", "orientation": "feet_on_floor"},
    )
    builder.add_marker(
        "07_MARKERS",
        "spawn_b",
        (23.0, -18.9, 0.0),
        {"marker_type": "spawn", "team": "B", "orientation": "feet_on_floor"},
    )
    builder.add_marker(
        "07_MARKERS",
        "light",
        (0.0, 14.0, 0.0),
        {"marker_type": "light", "suggested_energy": 16.0},
    )
    builder.add_marker(
        "07_MARKERS",
        "Map_Center",
        (0.0, 0.0, 0.0),
        {"marker_type": "design_reference"},
    )
    return builder


def transform_point(obj: dict, point: tuple[float, float, float]) -> tuple[float, float, float]:
    scaled = tuple(point[i] * obj["scale"][i] for i in range(3))
    rotated = rotate_vector(obj["rotation"], scaled)
    return tuple(rotated[i] + obj["translation"][i] for i in range(3))


def make_preview(objects: list[dict]) -> None:
    width, height = 1500, 1050
    image = Image.new("RGB", (width, height), (10, 14, 22))
    draw = ImageDraw.Draw(image, "RGBA")
    camera = (62.0, 48.0, 62.0)
    target = (0.0, -1.0, 0.0)
    forward = normalize(tuple(target[i] - camera[i] for i in range(3)))
    right = normalize(cross(forward, (0.0, 1.0, 0.0)))
    up = normalize(cross(right, forward))
    focal = 1120.0
    center = (width * 0.49, height * 0.52)

    def project(point: tuple[float, float, float]) -> tuple[float, float, float]:
        relative = tuple(point[i] - camera[i] for i in range(3))
        depth = sum(relative[i] * forward[i] for i in range(3))
        x = sum(relative[i] * right[i] for i in range(3))
        y = sum(relative[i] * up[i] for i in range(3))
        return center[0] + focal * x / depth, center[1] - focal * y / depth, depth

    cube_corners = [
        (-0.5, -0.5, -0.5), (0.5, -0.5, -0.5), (0.5, 0.5, -0.5), (-0.5, 0.5, -0.5),
        (-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5), (-0.5, 0.5, 0.5),
    ]
    faces = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (3, 2, 6, 7), (1, 5, 6, 2), (0, 3, 7, 4)]
    polygons: list[tuple[float, list[tuple[float, float]], tuple[int, int, int, int]]] = []

    for obj in objects:
        # Hide the ceiling and camera-side hull panels to expose the playable interior.
        name = obj["name"]
        if name == "Hull_Ceiling":
            continue
        if name.startswith("Hull_Wall_"):
            x, _, z = obj["translation"]
            if x > 5.0 or z > 5.0:
                continue
        if obj["kind"] == "Prism12":
            ring = []
            for i in range(12):
                angle = 2.0 * math.pi * i / 12.0
                point = transform_point(obj, (math.cos(angle), 0.5, math.sin(angle)))
                ring.append(project(point))
            color = tuple(int(channel * 255) for channel in MATERIALS[obj["material"]][:3])
            polygons.append((
                sum(point[2] for point in ring) / len(ring),
                [(point[0], point[1]) for point in ring],
                (*color, 180),
            ))
            continue

        projected = [project(transform_point(obj, corner)) for corner in cube_corners]
        base = tuple(int(channel * 255) for channel in MATERIALS[obj["material"]][:3])
        for face_index, face in enumerate(faces):
            points = [projected[index] for index in face]
            shade = 0.68 + 0.06 * face_index
            color = tuple(min(255, int(channel * shade)) for channel in base)
            alpha = 205 if name.startswith(("Catcher_", "Core_", "Objective_")) else 165
            polygons.append((
                sum(point[2] for point in points) / 4.0,
                [(point[0], point[1]) for point in points],
                (*color, alpha),
            ))

    for _, polygon, color in sorted(polygons, key=lambda entry: entry[0], reverse=True):
        draw.polygon(polygon, fill=color)
        draw.line(polygon + [polygon[0]], fill=(205, 220, 235, 80), width=1)

    try:
        title_font = ImageFont.truetype("arialbd.ttf", 34)
        body_font = ImageFont.truetype("arial.ttf", 20)
    except OSError:
        title_font = ImageFont.load_default()
        body_font = ImageFont.load_default()

    draw.rounded_rectangle((32, 28, 660, 126), radius=16, fill=(8, 12, 20, 220), outline=(90, 120, 150, 180), width=2)
    draw.text((54, 45), "ZERO-G REACTOR ARENA", font=title_font, fill=(238, 246, 255, 255))
    draw.text((56, 90), "GLB blockout · ceiling/front hull hidden in preview", font=body_font, fill=(160, 185, 210, 255))

    legend = [
        ("Cyan / orange", "high-speed catcher routes"),
        ("Silver", "porous central reactor"),
        ("Green", "outer recovery shelves"),
        ("Blue / red", "protected spawn bays"),
    ]
    legend_x, legend_y = 1060, 820
    draw.rounded_rectangle((legend_x - 24, legend_y - 26, 1465, 1018), radius=14, fill=(8, 12, 20, 215), outline=(90, 120, 150, 160), width=2)
    for index, (label, description) in enumerate(legend):
        y = legend_y + index * 43
        draw.text((legend_x, y), label, font=body_font, fill=(235, 242, 250, 255))
        draw.text((legend_x, y + 21), description, font=body_font, fill=(145, 170, 195, 255))

    image.save(PREVIEW_PATH)


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    builder = build_arena()
    gltf = builder.finish_scene()
    builder.write(gltf)
    make_preview(builder.preview_objects)
    print(f"Wrote {GLB_PATH} ({GLB_PATH.stat().st_size:,} bytes)")
    print(f"Wrote {PREVIEW_PATH} ({PREVIEW_PATH.stat().st_size:,} bytes)")
    print(f"Nodes: {len(gltf['nodes'])}; mesh definitions: {len(gltf['meshes'])}")


if __name__ == "__main__":
    main()
