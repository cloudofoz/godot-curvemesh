# Copyright (C) 2022 Claudio Z. (cloudofoz)
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

@tool
extends Path3D

#---------------------------------------------------------------------------------------------------
# CONSTANTS
#---------------------------------------------------------------------------------------------------
const CM_HALF_PI = PI / 2.0

#---------------------------------------------------------------------------------------------------
# PUBLIC VARIABLES
#---------------------------------------------------------------------------------------------------
@export_category("CurveMesh3D")

## Sets the radius of the generated mesh
@export_range(0.001, 1.0, 0.0001, "or_greater") var radius: float = 0.1:
	set(value):
		radius = value
		curve_changed.emit()

## Use this [Curve] to modify the mesh radius
@export var radius_profile: Curve:
	set(value):
		radius_profile = value
		if(radius_profile != null):
			radius_profile.changed.connect(cm_on_curve_changed)
		curve_changed.emit()

## Number of vertices of a circular section.
## To increase the curve subdivisions you can change [Property: curve.bake_interval] instead.
@export_range(4, 64, 1) var radial_resolution: int = 8:
	set(value):
		radial_resolution = value
		curve_changed.emit()

## Material of the generated mesh surface
@export var material: StandardMaterial3D:
	set(value):
		material = value
		if(cm_mesh && cm_mesh.get_surface_count() > 0): 
			cm_mesh.surface_set_material(0, value)


@export_group("Caps", "cap_")

## If 'true' the generated mesh starts with an hemispherical surface
@export var cap_start: bool = true:
	set(value):
		cap_start = value
		curve_changed.emit()

## If 'true' the generated mesh ends with an hemispherical surface
@export var cap_end: bool = true:
	set(value):
		cap_end = value
		curve_changed.emit()
 
## Number of rings that are used to create the hemispherical cap
## note: the number of vertices of each ring depends on [radial_resolution]
@export_range(1, 32, 1, "or_greater") var cap_rings: int = 4:
	set(value):
		cap_rings = value
		curve_changed.emit()

## Scale caps UV coords by this factor
@export var cap_uv_scale: float = 0.1:
	set(value):
		cap_uv_scale = value
		curve_changed.emit()

## Shift caps UV coords by this offset 
@export var cap_uv_offset: Vector2 = Vector2.ZERO:
	set(value):
		cap_uv_offset = value
		curve_changed.emit()


@export_group("View", "cm_")

## Turn this off to disable mesh generation
@export var cm_enabled = true:
	set(value):
		cm_enabled = value
		if(!value): cm_clear()
		else: curve_changed.emit()

## If [cm_debug_mode=true] the node will draw only a run-time visibile curve
@export var cm_debug_mode = false:
	set(value):
		cm_debug_mode = value
		curve_changed.emit()

#---------------------------------------------------------------------------------------------------
# PRIVATE VARIABLES
#---------------------------------------------------------------------------------------------------

var cm_mesh_instance: MeshInstance3D = null
var cm_mesh: ArrayMesh = null
var cm_st: SurfaceTool = null

#---------------------------------------------------------------------------------------------------
# STATIC METHODS
#---------------------------------------------------------------------------------------------------

## creates a mat3x4 to align a point on a plane orthogonal to the direction
## note: geometry is firstly created on a XZ plane (normal: 0.0, 1.0, 0.0)
static func cm_get_aligned_transform(from: Vector3, to: Vector3, t: float) -> Transform3D:
	var up = Vector3.UP # normal of a XZ plane
	var direction = (to - from).normalized() 
	var center = from.move_toward(to, t)
	var axis = direction.cross(up).normalized()
	var angle = direction.angle_to(up)
	return Transform3D.IDENTITY.rotated(axis, angle).translated_local(-center)

static func cm_get_curve_length(plist: PackedVector3Array) -> float:
	var d = 0.0
	var pcount = plist.size()
	for i in range(0, pcount - 1):
		d += plist[i].distance_to(plist[i+1])
	return d

#---------------------------------------------------------------------------------------------------
# VIRTUAL METHODS
#---------------------------------------------------------------------------------------------------

func _ready() -> void:
	cm_clear_duplicated_internal_children()
	if(!cm_st): 
		cm_st = SurfaceTool.new()
	if(!cm_mesh): 
		cm_mesh = ArrayMesh.new()
	else: 
		cm_mesh.clear_surfaces()
	if(!cm_mesh_instance):
		cm_mesh_instance = MeshInstance3D.new()
		cm_mesh_instance.mesh = cm_mesh
		cm_mesh_instance.set_meta("__cm3d_internal__", true)
		add_child(cm_mesh_instance)
	if(!curve || curve.point_count < 2): 
		curve = cm_create_default_curve()
	if(!material): 
		material = cm_create_default_material()
	if(!radius_profile): 
		self.radius_profile = cm_create_default_radius_profile()
	curve_changed.connect(cm_on_curve_changed)
	curve_changed.emit()

#---------------------------------------------------------------------------------------------------
# CALLBACKS
#---------------------------------------------------------------------------------------------------

# rebuild when some property changes
func cm_on_curve_changed() -> void:
	if(!cm_enabled): return
	if(!cm_debug_mode): cm_build_curve()
	else: cm_debug_draw()

#---------------------------------------------------------------------------------------------------
# PRIVATE METHODS
#---------------------------------------------------------------------------------------------------

func cm_get_radius(t: float):
	if(!radius_profile || radius_profile.point_count == 0):
		return radius
	return radius * radius_profile.sample(t)

func cm_gen_circle_verts(t3d: Transform3D, t: float = 0.0):
	var rad_step: float = TAU / radial_resolution
	var center = Vector3.ZERO * t3d
	var r = cm_get_radius(t)
	for i in range(0, radial_resolution + 1):
		var k = i % radial_resolution
		var angle = k * rad_step
		var v = Vector3(r * cos(angle), 0.0, r * sin(angle)) * t3d
		cm_st.set_normal((v-center).normalized())
		cm_st.set_uv(Vector2(float(i) / radial_resolution, t))
		cm_st.add_vertex(v)

func cm_gen_curve_segment(start_ring_idx: int):
	# radial_resolution +1 because: first and last vertices are in the same position 
	# BUT have 2 different UVs: v_first = uv[0.0, y_coord] | v_last = uv[1.0, y_coord] 
	var ring_vtx_count = radial_resolution + 1 
	start_ring_idx *= ring_vtx_count
	for a in range(start_ring_idx, start_ring_idx + radial_resolution):
		var b = a + 1
		var d = a + ring_vtx_count
		var c = d + 1
		cm_st.add_index(a)
		cm_st.add_index(b)
		cm_st.add_index(c)
		cm_st.add_index(a)
		cm_st.add_index(c)
		cm_st.add_index(d)

func cm_gen_curve_segments_range(start_ring_idx: int, ring_count: int) -> int:
	for i in ring_count:
		cm_gen_curve_segment(start_ring_idx + i)
	return start_ring_idx + ring_count

# parametric eq. for hemisphere on a XZ plane:
#1. x = x0 + r * sin(beta) * cos(alpha)
#2. y = z0 + r * cos(beta)
#3. z = y0 + r * sin(beta) * sin(alpha)
#4. 0 <= beta  <= HALF_PI                 # "it's an hemisphere!"
#5. 0 <= alpha <= TAU                     # TAU = 2 * PI
func cm_gen_cap_verts(t3d: Transform3D, is_cap_start: bool):
	var alpha_step: float = TAU / radial_resolution
	var beta_step: float = CM_HALF_PI / cap_rings
	var c = Vector3.ZERO * t3d
	var r: float
	var beta_offset: float
	var beta_direction: float
	if is_cap_start:
			r = cm_get_radius(0.0)
			beta_offset = CM_HALF_PI
			beta_direction = +1.0
	else: #is_cap_end
			r = cm_get_radius(1.0)
			beta_offset = 0.0
			beta_direction = -1.0
	for ring_idx in range(cap_rings, -1, -1):
		var beta = beta_offset + ring_idx * beta_step * beta_direction
		var sin_beta = sin(beta)
		var cos_beta = cos(beta)
		for v_idx in (radial_resolution + 1):
			var alpha = (v_idx % radial_resolution) * alpha_step
			var v = Vector3(r * sin_beta * cos(alpha), r * cos_beta, r * sin_beta * sin(alpha)) * t3d
			cm_st.set_uv(Vector2(float(v_idx) / float(radial_resolution), 1.0) * sin_beta * cap_uv_scale + cap_uv_offset) 
			cm_st.set_normal((v-c).normalized())
			cm_st.add_vertex(v)

func cm_gen_vertices():
	if(!curve): return 0
	var plist = curve.get_baked_points() as PackedVector3Array
	var psize = plist.size()
	if(psize < 2): return 0
	var cur_length = 0.0
	var total_length = cm_get_curve_length(plist)
	var t3d = cm_get_aligned_transform(plist[0], plist[1], 0.0)
	if(cap_start): cm_gen_cap_verts(t3d, true)
	cm_gen_circle_verts(t3d, 0.0)
	for i in range(0, psize - 1):
		cur_length += plist[i].distance_to(plist[i + 1])
		t3d = cm_get_aligned_transform(plist[i], plist[i + 1], 1.0)
		cm_gen_circle_verts(t3d, min(cur_length / total_length, 1.0))
	if(cap_end): cm_gen_cap_verts(t3d, false)
	return psize

# The whole mesh could be generated by one call, like this:
# cm_gen_curve_segments_range(0, cap_rings * 2 + psize - 1).
# But, at the moment, the two caps have a different uv mapping than the curve mesh.
# For this reason caps don't share vertices with the main curve and so 
# we need 3 separated calls of 'cm_gen_curve_segments_range()':
# cap_start_mesh |+1| curve_mesh |+1| cap_end_mesh
# (+1 means that we "jump" to another set of vertices).
func cm_gen_faces(psize: int):
	var start_idx: int = 0
	if(cap_start):
		start_idx = cm_gen_curve_segments_range(0, cap_rings) + 1
	start_idx = cm_gen_curve_segments_range(start_idx, psize - 1) + 1
	if(cap_end):
		start_idx = cm_gen_curve_segments_range(start_idx, cap_rings) + 1

func cm_clear() -> bool:
	if(!cm_st || !cm_mesh): return false
	cm_st.clear()
	cm_mesh.clear_surfaces()
	return true

# commits the computed geometry to the mesh array
func cm_curve_to_mesh_array():
	cm_st.commit(cm_mesh)
	cm_mesh.surface_set_material(0, material)

func cm_build_curve():
	if(!cm_clear()): return
	cm_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var psize = cm_gen_vertices()
	if(psize < 2): return
	cm_gen_faces(psize)
	cm_curve_to_mesh_array()

func cm_debug_draw():
	if(!cm_clear()): return
	cm_st.begin(Mesh.PRIMITIVE_LINE_STRIP)
	for v in curve.get_baked_points():
		cm_st.add_vertex(v)
	cm_curve_to_mesh_array()

func cm_create_default_curve() -> Curve3D:
	var c = Curve3D.new()
	var ctp = Vector3(0.6, 0.46, 0)
	c.add_point(Vector3.ZERO, ctp, ctp)
	c.add_point(Vector3.UP, -ctp, -ctp)
	c.bake_interval = 0.1
	return c

func cm_create_default_material() -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color.from_string("009de1", Color.LIGHT_SKY_BLUE)
	mat.roughness = 0.5
	return mat

func cm_create_default_radius_profile() -> Curve:
	var c = Curve.new()
	c.add_point(Vector2(0.0, 0.05))
#	c.add_point(Vector2(0.5, 0.5))
	c.add_point(Vector2(1.0, 1.0))
	return c

func cm_clear_duplicated_internal_children():
	for c in get_children(): 
		if(c.get_meta("__cm3d_internal__", false)):
			c.queue_free()
