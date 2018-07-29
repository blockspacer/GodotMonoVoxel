tool
extends Spatial

const QuadTreeLod = preload("quad_tree_lod.gd")
const Mesher = preload("hterrain_mesher.gd")
const Grid = preload("grid.gd")
var HTerrainData = load("res://addons/zylann.hterrain/hterrain_data.gd")
const HTerrainChunk = preload("hterrain_chunk.gd")
const Util = preload("util.gd")

const DefaultShader = preload("shaders/simple4.shader")

const CHUNK_SIZE = 16

const SHADER_PARAM_HEIGHT_TEXTURE = "height_texture"
const SHADER_PARAM_NORMAL_TEXTURE = "normal_texture"
const SHADER_PARAM_COLOR_TEXTURE = "color_texture"
const SHADER_PARAM_SPLAT_TEXTURE = "splat_texture"
const SHADER_PARAM_MASK_TEXTURE = "mask_texture"
const SHADER_PARAM_RESOLUTION = "heightmap_resolution"
const SHADER_PARAM_INVERSE_TRANSFORM = "heightmap_inverse_transform"
const SHADER_PARAM_DETAIL_ALBEDO = "detail_albedo_" # 0, 1, 2, 3...
const SHADER_PARAM_DETAIL_NORMAL = "detail_normal_" # 0, 1, 2, 3...
const SHADER_PARAM_DETAIL_BUMP = "detail_bump_" # 0, 1, 2, 3...

const SHADER_SIMPLE4 = 0
#const SHADER_ARRAY = 1

const DETAIL_ALBEDO = 0
const DETAIL_NORMAL = 1
const DETAIL_BUMP = 2


export var depth_blending = false

var _custom_material = null
var _material = null
var _collision_enabled = false
var _data = null

var _mesher = Mesher.new()
var _lodder = QuadTreeLod.new()

var _pending_chunk_updates = []

# [lod][pos]
# This container owns chunks
var _chunks = []

# Stats
var _updated_chunks = 0

var _edit_manual_viewer_pos = Vector3()


func _init():
	print("Create HeightMap")
	_lodder.set_callbacks(funcref(self, "_cb_make_chunk"), funcref(self,"_cb_recycle_chunk"))
	set_notify_transform(true)


# TODO TEMPORARY!!!
func _ready():
	if not has_data():
		set_data(HTerrainData.new())


func _get_property_list():
	var props = [
		{
			# Must do this to export a custom resource type
			"name": "data",
			"type": TYPE_OBJECT,
			"usage": PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR,
			"hint": PROPERTY_HINT_RESOURCE_TYPE,
			"hint_string": "HTerrainData"
		}
	]
	
	for i in range(get_detail_texture_slot_count()):
		props.append({
			"name": "detail/albedo_" + str(i),
			"type": TYPE_OBJECT,
			"usage": PROPERTY_USAGE_STORAGE,
			"hint": PROPERTY_HINT_RESOURCE_TYPE,
			"hint_string": "Texture"
		})
	
	return props


func _get(key):
	
	if key == "data":
		return get_data()
		
	elif key.begins_with("detail/albedo_"):
		var i = key.right(len(key) - 1).to_int()
		return get_detail_texture(i, DETAIL_ALBEDO)
		
	elif key.begins_with("detail/normal_"):
		var i = key.right(len(key) - 1).to_int()
		return get_detail_texture(i, DETAIL_NORMAL)
		
	elif key.begins_with("detail/bump_"):
		var i = key.right(len(key) - 1).to_int()
		return get_detail_texture(i, DETAIL_BUMP)


func _set(key, value):
	# Can't use setget when the exported type is custom,
	# because we were also are forced to use _get_property_list...
	if key == "data":
		set_data(value)
	
	elif key.begins_with("detail/albedo_"):
		var i = key.right(len(key) - 1).to_int()
		set_detail_texture(i, DETAIL_ALBEDO, value)

	elif key.begins_with("detail/normal_"):
		var i = key.right(len(key) - 1).to_int()
		set_detail_texture(i, DETAIL_NORMAL, value)

	elif key.begins_with("detail/bump_"):
		var i = key.right(len(key) - 1).to_int()
		set_detail_texture(i, DETAIL_BUMP, value)


func get_custom_material():
	return _custom_material


func is_collision_enabled():
	return _collision_enabled


func set_collision_enabled(enabled):
	_collision_enabled = enabled
	# TODO Update chunks / enable heightmap collider (or will be done through a different node perhaps)


func for_all_chunks(action):
	for lod in range(len(_chunks)):
		var grid = _chunks[lod]
		for y in range(len(grid)):
			var row = grid[y]
			for x in range(len(row)):
				var chunk = row[x]
				if chunk != null:
					action.exec(chunk)


func _notification(what):
	match what:
		
		NOTIFICATION_PREDELETE:
			print("Destroy HeightMap")
			# Note: might get rid of a circular ref in GDScript port
			clear_all_chunks()

		NOTIFICATION_ENTER_WORLD:
			print("Enter world")
			for_all_chunks(EnterWorldAction.new(get_world()))

		NOTIFICATION_EXIT_WORLD:
			print("Exit world");
			for_all_chunks(ExitWorldAction.new())

		NOTIFICATION_TRANSFORM_CHANGED:
			print("Transform changed");
			for_all_chunks(TransformChangedAction.new(get_global_transform()))
			update_material()

		NOTIFICATION_VISIBILITY_CHANGED:
			print("Visibility changed");
			for_all_chunks(VisibilityChangedAction.new(is_visible()))


func _enter_tree():
	print("Enter tree")
	set_process(true)


func clear_all_chunks():

	# The lodder has to be cleared because otherwise it will reference dangling pointers
	_lodder.clear();

	#for_all_chunks(DeleteChunkAction.new())

	for i in range(len(_chunks)):
		_chunks[i].clear()


func get_chunk_at(pos_x, pos_y, lod):
	if lod < len(_chunks):
		return Grid.grid_get_or_default(_chunks[lod], pos_x, pos_y, null)
	return null


func get_data():
	return _data


func has_data():
	return _data != null


func set_data(new_data):
	assert(new_data == null or new_data is HTerrainData)

	print("Set new data ", new_data)

	if(_data == new_data):
		return

	if has_data():
		print("Disconnecting old HeightMapData")
		_data.disconnect("resolution_changed", self, "_on_data_resolution_changed")
		_data.disconnect("region_changed", self, "_on_data_region_changed")

	_data = new_data

	# Note: the order of these two is important
	clear_all_chunks()

	if has_data():
		print("Connecting new HeightMapData")

		# This is a small UX improvement so that the user sees a default terrain
		if is_inside_tree() and Engine.is_editor_hint():
			if _data.get_resolution() == 0:
				_data.load_default()

		_data.connect("resolution_changed", self, "_on_data_resolution_changed")
		_data.connect("region_changed", self, "_on_data_region_changed")

		_on_data_resolution_changed()

		update_material()

	print("Set data done")


func _on_data_resolution_changed():

	clear_all_chunks();

	_pending_chunk_updates.clear();

	_lodder.create_from_sizes(CHUNK_SIZE, _data.get_resolution())

	_chunks.resize(_lodder.get_lod_count())

	var cres = _data.get_resolution() / CHUNK_SIZE
	var csize_x = cres
	var csize_y = cres
	
	for lod in range(_lodder.get_lod_count()):
		print("Create grid for lod ", lod, ", ", csize_x, "x", csize_y)
		var grid = Grid.create_grid(csize_x, csize_y)
		_chunks[lod] = grid
		csize_x /= 2
		csize_y /= 2

	_mesher.configure(CHUNK_SIZE, CHUNK_SIZE, _lodder.get_lod_count())
	update_material()


func _on_data_region_changed(min_x, min_y, max_x, max_y, channel):
	#print_line(String("_on_data_region_changed {0}, {1}, {2}, {3}").format(varray(min_x, min_y, max_x, max_y)));
	set_area_dirty(min_x, min_y, max_x - min_x, max_y - min_y)


func set_custom_material(p_material):
	assert(p_material == null or p_material is ShaderMaterial)
	
	if _custom_material != p_material:
		_custom_material = p_material

		if _custom_material != null:

			if is_inside_tree() and Engine.is_editor_hint():

				# When the new shader is empty, allows to fork from the default shader

				if _custom_material.get_shader() == null:
					_custom_material.set_shader(Shader.new())

				var shader = _custom_material.get_shader()
				if shader != null:
					if shader.get_code().empty():
						shader.set_code(DefaultShader.code)
					
					# TODO If code isn't empty,
					# verify existing parameters and issue a warning if important ones are missing

		update_material()


func update_material():

	var instance_changed = false;

	if _custom_material != null:

		if _custom_material != _material:
			# Duplicate material but not the shader.
			# This is to ensure that users don't end up with internal textures assigned in the editor,
			# which could end up being saved as regular textures (which is not intented).
			# Also the HeightMap may use multiple instances of the material in the future,
			# if chunks need different params or use multiple textures (streaming)
			_material = _custom_material.duplicate(false)
			instance_changed = true

	else:

		if _material == null:
			_material = ShaderMaterial.new()
			instance_changed = true
		
		_material.set_shader(DefaultShader)

	if instance_changed:
		for_all_chunks(SetMaterialAction.new(_material))

	update_material_params()


func update_material_params():

	assert(_material != null)
	
	var material = _material

	if _custom_material != null:
		# Copy all parameters from the custom material into the internal one
		# TODO We could get rid of this every frame if ShaderMaterial had a signal when a parameter changes...

		var from_shader = _custom_material.get_shader();
		var to_shader = _material.get_shader();

		assert(from_shader != null)
		assert(to_shader != null)
		# If that one fails, it means there is a bug in HeightMap code
		assert(from_shader == to_shader)

		# TODO Getting params could be optimized, by connecting to the Shader.changed signal and caching them

		var params_array = VisualServer.shader_get_param_list(from_shader.get_rid())

		var custom_material = _custom_material

		for i in range(len(params_array)):
			var d = params_array[i]
			var name = d["name"]
			material.set_shader_param(name, custom_material.get_shader_param(name))

	var height_texture
	var normal_texture
	var color_texture
	var splat_texture
	var mask_texture
	var res = Vector2(-1,-1)

	# TODO Only get textures the shader supports

	if has_data():
		height_texture = _data.get_texture(HTerrainData.CHANNEL_HEIGHT)
		normal_texture = _data.get_texture(HTerrainData.CHANNEL_NORMAL)
		color_texture = _data.get_texture(HTerrainData.CHANNEL_COLOR)
		splat_texture = _data.get_texture(HTerrainData.CHANNEL_SPLAT)
		mask_texture = _data.get_texture(HTerrainData.CHANNEL_MASK)
		res.x = _data.get_resolution()
		res.y = res.x

	if is_inside_tree():
		var gt = get_global_transform()
		var t = gt.affine_inverse()
		material.set_shader_param(SHADER_PARAM_INVERSE_TRANSFORM, t)

	material.set_shader_param(SHADER_PARAM_HEIGHT_TEXTURE, height_texture)
	material.set_shader_param(SHADER_PARAM_NORMAL_TEXTURE, normal_texture)
	material.set_shader_param(SHADER_PARAM_COLOR_TEXTURE, color_texture)
	material.set_shader_param(SHADER_PARAM_SPLAT_TEXTURE, splat_texture)
	material.set_shader_param(SHADER_PARAM_MASK_TEXTURE, mask_texture)
	material.set_shader_param(SHADER_PARAM_RESOLUTION, res)
	material.set_shader_param("depth_blending", depth_blending)


func set_lod_scale(lod_scale):
	_lodder.set_split_scale(lod_scale)


func get_lod_scale():
	return _lodder.get_split_scale()


func get_lod_count():
	return _lodder.get_lod_count()


#        3
#      o---o
#    0 |   | 1
#      o---o
#        2
# Directions to go to neighbor chunks
const s_dirs = [
	[-1, 0], # SEAM_LEFT
	[1, 0], # SEAM_RIGHT
	[0, -1], # SEAM_BOTTOM
	[0, 1] # SEAM_TOP
]

#       7   6
#     o---o---o
#   0 |       | 5
#     o       o
#   1 |       | 4
#     o---o---o
#       2   3
#
# Directions to go to neighbor chunks of higher LOD
const s_rdirs = [
	[-1, 0],
	[-1, 1],
	[0, 2],
	[1, 2],
	[2, 1],
	[2, 0],
	[1, -1],
	[0, -1]
]

func _process(delta):
		
	# Get viewer pos
	var viewer_pos = _edit_manual_viewer_pos
	var viewport = get_viewport()
	if viewport != null:
		var camera = viewport.get_camera()
		if camera != null:
			viewer_pos = camera.get_global_transform().origin

	if has_data():
		_lodder.update(viewer_pos)

	_updated_chunks = 0

	# Add more chunk updates for neighboring (seams):
	# This adds updates to higher-LOD chunks around lower-LOD ones,
	# because they might not needed to update by themselves, but the fact a neighbor
	# chunk got joined or split requires them to create or revert seams
	var precount = _pending_chunk_updates.size()
	for i in range(precount):
		var u = _pending_chunk_updates[i]

		# In case the chunk got split
		for d in range(4):

			var ncpos_x = u.pos_x + s_dirs[d][0]
			var ncpos_y = u.pos_y + s_dirs[d][1]
			
			var nchunk = get_chunk_at(ncpos_x, ncpos_y, u.lod)

			if nchunk != null and nchunk.is_active():
				# Note: this will append elements to the array we are iterating on,
				# but we iterate only on the previous count so it should be fine
				add_chunk_update(nchunk, ncpos_x, ncpos_y, u.lod)

		# In case the chunk got joined
		if u.lod > 0:
			var cpos_upper_x = u.pos_x * 2
			var cpos_upper_y = u.pos_y * 2
			var nlod = u.lod - 1

			for rd in range(8):

				var ncpos_upper_x = cpos_upper_x + s_rdirs[rd][0]
				var ncpos_upper_y = cpos_upper_y + s_rdirs[rd][1]
				
				var nchunk = get_chunk_at(ncpos_upper_x, ncpos_upper_y, nlod)

				if nchunk != null and nchunk.is_active():
					add_chunk_update(nchunk, ncpos_upper_x, ncpos_upper_y, nlod)

	# Update chunks
	for i in range(len(_pending_chunk_updates)):
		
		var u = _pending_chunk_updates[i]
		var chunk = get_chunk_at(u.pos_x, u.pos_y, u.lod)
		assert(chunk != null)
		update_chunk(chunk, u.lod)

	_pending_chunk_updates.clear()

	if Engine.editor_hint:
		# TODO I would reaaaally like to get rid of this... it just looks inefficient,
		# and it won't play nice if more materials are used internally.
		# Initially needed so that custom materials can be tweaked in editor.
		update_material_params()

	# DEBUG
#	if(_updated_chunks > 0):
#		print("Updated {0} chunks".format(_updated_chunks))


func update_chunk(chunk, lod):
	assert(has_data())

	# Check for my own seams
	var seams = 0;
	var cpos_x = chunk.cell_origin_x / (CHUNK_SIZE << lod)
	var cpos_y = chunk.cell_origin_y / (CHUNK_SIZE << lod)
	var cpos_lower_x = cpos_x / 2
	var cpos_lower_y = cpos_y / 2

	# Check for lower-LOD chunks around me
	for d in range(4):
		var ncpos_lower_x = (cpos_x + s_dirs[d][0]) / 2
		var ncpos_lower_y = (cpos_y + s_dirs[d][1]) / 2
		if ncpos_lower_x != cpos_lower_x or ncpos_lower_y != cpos_lower_y:
			var nchunk = get_chunk_at(ncpos_lower_x, ncpos_lower_y, lod + 1)
			if nchunk != null and nchunk.is_active():
				seams |= (1 << d)

	var mesh = _mesher.get_chunk(lod, seams)
	chunk.set_mesh(mesh)

	# Because chunks are rendered using vertex shader displacement,
	# the renderer cannot rely on the mesh's AABB.
	var s = CHUNK_SIZE << lod;
	var aabb = _data.get_region_aabb(chunk.cell_origin_x, chunk.cell_origin_y, s, s)
	aabb.position.x = 0
	aabb.position.z = 0
	chunk.set_aabb(aabb)

	_updated_chunks += 1

	chunk.set_visible(is_visible())
	chunk.set_pending_update(false)

#	if (get_tree()->is_editor_hint() == false) {
#		// TODO Generate collider? Or delegate this to another node
#	}


func add_chunk_update(chunk, pos_x, pos_y, lod):

	if chunk.is_pending_update():
		#print_line("Chunk update is already pending!");
		return

	assert(lod < len(_chunks))
	assert(pos_x >= 0)
	assert(pos_y >= 0)
	assert(pos_y < len(_chunks[lod]))
	assert(pos_x < len(_chunks[lod][pos_y]))

	# No update pending for this chunk, create one
	var u = PendingChunkUpdate.new()
	u.pos_x = pos_x
	u.pos_y = pos_y
	u.lod = lod
	_pending_chunk_updates.push_back(u)

	chunk.set_pending_update(true)

	# TODO Neighboring chunks might need an update too because of normals and seams being updated


func set_area_dirty(origin_in_cells_x, origin_in_cells_y, size_in_cells_x, size_in_cells_y):

	var cpos0_x = origin_in_cells_x / CHUNK_SIZE
	var cpos0_y = origin_in_cells_y / CHUNK_SIZE
	var csize_x = (size_in_cells_x - 1) / CHUNK_SIZE + 1
	var csize_y = (size_in_cells_y - 1) / CHUNK_SIZE + 1

	# For each lod
	for lod in range(_lodder.get_lod_count()):

		# Get grid and chunk size
		var grid = _chunks[lod]
		var s = _lodder.get_lod_size(lod)

		# Convert rect into this lod's coordinates:
		# Pick min and max (included), divide them, then add 1 to max so it's excluded again
		var min_x = cpos0_x / s
		var min_y = cpos0_y / s
		var max_x = (cpos0_x + csize_x - 1) / s + 1
		var max_y = (cpos0_y + csize_y - 1) / s + 1

		# Find which chunks are within
		var cy = min_y
		while cy < max_y:
			var cx = min_x
			while cx < max_x:
				
				var chunk = Grid.grid_get_or_default(grid, cx, cy, null)

				if chunk != null and chunk.is_active():
					add_chunk_update(chunk, cx, cy, lod)
				
				cx += 1
			cy += 1
		

# Called when a chunk is needed to be seen
func _cb_make_chunk(cpos_x, cpos_y, lod):

	# TODO What if cpos is invalid? get_chunk_at will return NULL but that's still invalid
	var chunk = get_chunk_at(cpos_x, cpos_y, lod)

	if chunk == null:
		# This is the first time this chunk is required at this lod, generate it

		var lod_factor = _lodder.get_lod_size(lod)
		var origin_in_cells_x = cpos_x * CHUNK_SIZE * lod_factor
		var origin_in_cells_y = cpos_y * CHUNK_SIZE * lod_factor
		
		chunk = HTerrainChunk.new(self, origin_in_cells_x, origin_in_cells_y, _material)
		
		var grid = _chunks[lod]
		var row = grid[cpos_y]
		row[cpos_x] = chunk

	# Make sure it gets updated
	add_chunk_update(chunk, cpos_x, cpos_y, lod);

	chunk.set_active(true)

	return chunk;


# Called when a chunk is no longer seen
func _cb_recycle_chunk(chunk, cx, cy, lod):
	chunk.set_visible(false);
	chunk.set_active(false);


func local_pos_to_cell(local_pos):
	return [
		int(local_pos.x),
		int(local_pos.z)
	]


static func get_height_or_default(im, pos_x, pos_y):
	if pos_x < 0 or pos_y < 0 or pos_x >= im.get_width() or pos_y >= im.get_height():
		return 0
	return im.get_pixel(pos_x, pos_y).r


func cell_raycast(origin_world, dir_world, out_cell_pos):
	assert(typeof(origin_world) == TYPE_VECTOR3)
	assert(typeof(dir_world) == TYPE_VECTOR3)
	assert(typeof(out_cell_pos) == TYPE_ARRAY)

	if not has_data():
		return false

	var heights = _data.get_image(HTerrainData.CHANNEL_HEIGHT)
	if heights == null:
		return false

	var to_local = get_global_transform().affine_inverse()
	var origin = to_local.xform(origin_world)
	var dir = to_local.basis.xform(dir_world)

	heights.lock()

	var cpos = local_pos_to_cell(origin)
	if origin.y < get_height_or_default(heights, cpos[0], cpos[1]):
		# Below
		return false

	var unit = 1.0
	var d = 0.0
	var max_distance = 800.0
	var pos = origin

	# Slow, but enough for edition
	# TODO Could be optimized with a form of binary search
	while d < max_distance:
		pos += dir * unit
		cpos = local_pos_to_cell(origin)
		if get_height_or_default(heights, cpos[0], cpos[1]) > pos.y:
			cpos = local_pos_to_cell(pos - dir * unit);
			out_cell_pos[0] = cpos[0]
			out_cell_pos[1] = cpos[1]
			return true
		
		d += unit

	return false


func get_detail_texture(slot, type):
	assert(slot >= 0 and slot < get_detail_texture_slot_count())
	match type:
		DETAIL_ALBEDO:
			return _material.get_shader_param(SHADER_PARAM_DETAIL_ALBEDO + str(slot))
		DETAIL_NORMAL:
			return _material.get_shader_param(SHADER_PARAM_DETAIL_NORMAL + str(slot))
		DETAIL_BUMP:
			return _material.get_shader_param(SHADER_PARAM_DETAIL_BUMP + str(slot))
		_:
			print("Unknown texture type ", type)
	return null


func set_detail_texture(slot, type, tex):
	assert(slot >= 0 and slot < get_detail_texture_slot_count())
	match type:
		DETAIL_ALBEDO:
			_material.set_shader_param(SHADER_PARAM_DETAIL_ALBEDO + str(slot), tex)
		DETAIL_NORMAL:
			_material.set_shader_param(SHADER_PARAM_DETAIL_NORMAL + str(slot), tex)
		DETAIL_BUMP:
			_material.set_shader_param(SHADER_PARAM_DETAIL_BUMP + str(slot), tex)
		_:
			print("Unknown texture type ", type)


static func get_detail_texture_slot_count_for_shader(mode):
	match mode:
		SHADER_SIMPLE4:
			return 4
#		SHADER_ARRAY:
#			return 256
	print("Invalid shader type specified ", mode)
	return 0


func get_detail_texture_slot_count():
	return get_detail_texture_slot_count_for_shader(SHADER_SIMPLE4)


func _edit_set_manual_viewer_pos(pos):
	_edit_manual_viewer_pos = pos


func _edit_debug_draw(ci):
	_lodder.debug_draw_tree(ci)


class PendingChunkUpdate:
	var pos_x = 0
	var pos_y = 0
	var lod = 0


class EnterWorldAction:
	var world = null
	func _init(w):
		world = w
	func exec(chunk):
		chunk.enter_world(world)


class ExitWorldAction:
	func exec(chunk):
		chunk.exit_world()


class TransformChangedAction:
	var transform = null
	func _init(t):
		transform = t
	func exec(chunk):
		chunk.parent_transform_changed(transform)


class VisibilityChangedAction:
	var visible = false
	func _init(v):
		visible = v
	func exec(chunk):
		chunk.set_visible(visible)


#class DeleteChunkAction:
#	func exec(chunk):
#		pass


class SetMaterialAction:
	var material = null
	func _init(m):
		material = m
	func exec(chunk):
		chunk.set_material(material)

