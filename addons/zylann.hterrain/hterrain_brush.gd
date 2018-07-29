tool

const HTerrain = preload("hterrain.gd")
const HTerrainData = preload("hterrain_data.gd")
const Util = preload("util.gd")
const Grid = preload("grid.gd")

const MODE_ADD = 0
const MODE_SUBTRACT = 1
const MODE_SMOOTH = 2
const MODE_FLATTEN = 3
const MODE_SPLAT = 4
const MODE_COLOR = 5
const MODE_MASK = 6
const MODE_COUNT = 7

var _radius = 0
var _opacity = 1.0
var _shape = [] #Grid2D<float> _shape;
var _shape_sum = 0.0
var _shape_size = 0
var _mode = MODE_ADD
var _flatten_height = 0.0
var _texture_index = 0
var _texture_mode = HTerrain.SHADER_SIMPLE4
var _color = Color(1, 1, 1)
var _undo_cache = {}


func get_mode():
	return _mode


func set_mode(mode):
	assert(mode < MODE_COUNT)
	_mode = mode;
	# Different mode might affect other channels,
	# so we need to clear the current data otherwise it wouldn't make sense
	_undo_cache.clear()


func set_radius(p_radius):
	assert(typeof(p_radius) == TYPE_INT)
	if p_radius != _radius:
		assert(p_radius > 0)
		_radius = p_radius
		generate_procedural(_radius)
		# TODO Allow to set a texture as shape


func get_radius():
	return _radius


func set_opacity(opacity):
	_opacity = clamp(opacity, 0, 1)


func get_opacity():
	return _opacity


func set_flatten_height(flatten_height):
	_flatten_height = flatten_height


func get_flatten_height():
	return _flatten_height


func set_texture_index(tid):
	assert(tid >= 0)
	var slot_count = HTerrain.get_detail_texture_slot_count_for_shader(_texture_mode)
	assert(tid < slot_count)
	_texture_index = tid


func get_texture_index():
	return _texture_index


func set_color(c):
	# Color might be useful for custom shading
	_color = c


func get_color():
	return _color


func generate_procedural(radius):
	assert(typeof(radius) == TYPE_INT)
	assert(radius > 0)
	
	var size = 2 * radius
	
	_shape = Grid.create_grid(size, size)
	_shape_size = size

	_shape_sum = 0.0;

	for y in range(-radius, radius):
		for x in range(-radius, radius):
			
			var d = Vector2(x, y).distance_to(Vector2(0, 0)) / float(radius)
			var v = 1.0 - d * d * d
			if v > 1.0:
				v = 1.0
			if v < 0.0:
				v = 0.0
			
			_shape[y + radius][x + radius] = v
			_shape_sum += v;


func get_mode_channel(mode):
	match mode:
		MODE_ADD, \
		MODE_SUBTRACT, \
		MODE_SMOOTH, \
		MODE_FLATTEN:
			return HTerrainData.CHANNEL_HEIGHT	
		MODE_COLOR:
			return HTerrainData.CHANNEL_COLOR
		MODE_SPLAT:
			return HTerrainData.CHANNEL_SPLAT
		MODE_MASK:
			return HTerrainData.CHANNEL_MASK
		_:
			print("This mode has no channel")

	return HTerrainData.CHANNEL_COUNT # Error


func paint(height_map, cell_pos_x, cell_pos_y, override_mode):

	assert(height_map.get_data() != null)
	var data = height_map.get_data()

	var delta = _opacity * 1.0 / 60.0
	var mode = _mode

	if override_mode != -1:
		assert(override_mode >= 0 or override_mode < MODE_COUNT)
		mode = override_mode

	var origin_x = cell_pos_x - _shape_size / 2
	var origin_y = cell_pos_y - _shape_size / 2

	height_map.set_area_dirty(origin_x, origin_y, _shape_size, _shape_size)

	match mode:

		MODE_ADD:
			paint_height(data, origin_x, origin_y, 50.0 * delta)

		MODE_SUBTRACT:
			paint_height(data, origin_x, origin_y, -50.0 * delta)

		MODE_SMOOTH:
			smooth_height(data, origin_x, origin_y, delta)

		MODE_FLATTEN:
			flatten_height(data, origin_x, origin_y)

		MODE_SPLAT:
			paint_splat(data, origin_x, origin_y)

		MODE_COLOR:
			paint_color(data, origin_x, origin_y)

		MODE_MASK:
			paint_mask(data, origin_x, origin_y)

	data.notify_region_change([origin_x, origin_y], [_shape_size, _shape_size], get_mode_channel(mode))


# TODO Erk!
static func foreach_xy(op, data, origin_x, origin_y, speed, opacity, shape):
	
	var shape_size = shape.size()

	var s = opacity * speed

	var min_x = origin_x
	var min_y = origin_y
	var max_x = min_x + shape_size
	var max_y = min_y + shape_size
	var min_noclamp_x = min_x
	var min_noclamp_y = min_y

	var pmin = [min_x, min_y]
	var pmax = [max_x, max_y]
	Util.clamp_min_max_excluded(pmin, pmax, [0, 0], [data.get_resolution(), data.get_resolution()])
	min_x = pmin[0]
	min_y = pmin[1]
	max_x = pmax[0]
	max_y = pmax[1]

	for y in range(min_y, max_y):
		var py = y - min_noclamp_y
		
		for x in range(min_x, max_x):
			var px = x - min_noclamp_x

			var shape_value = shape[py][px]
			op.exec(data, x, y, s * shape_value)


class OperatorAdd:
	var _im = null
	func _init(im):
		_im = im
	func exec(data, pos_x, pos_y, v):
		var c = _im.get_pixel(pos_x, pos_y)
		c.r += v
		_im.set_pixel(pos_x, pos_y, c)


class OperatorSum:
	var sum = 0.0
	var _im = null
	func _init(im):
		_im = im
	func exec(data, pos_x, pos_y, v):
		sum += _im.get_pixel(pos_x, pos_y).r * v


class OperatorLerp:

	var target = 0.0
	var _im = null

	func _init(p_target, im):
		target = p_target
		_im = im

	func exec(data, pos_x, pos_y, v):
		var c = _im.get_pixel(pos_x, pos_y)
		c.r = lerp(c.r, target, v)
		_im.set_pixel(pos_x, pos_y, c)


class OperatorLerpColor:

	var target = Color()
	var _im = null

	func _init(p_target, im):
		target = p_target
		_im = im
	
	func exec(data, pos_x, pos_y, v):
		var c = _im.get_pixel(pos_x, pos_y)
		c = c.linear_interpolate(target, v)
		_im.set_pixel(pos_x, pos_y, c)


static func is_valid_pos(pos_x, pos_y, im):
	return not (pos_x < 0 or pos_y < 0 or pos_x >= im.get_width() or pos_y >= im.get_height())


func backup_for_undo(im, undo_cache, rect_origin_x, rect_origin_y, rect_size_x, rect_size_y):

	# Backup cells before they get changed,
	# using chunks so that we don't save the entire grid everytime.
	# This function won't do anything if all concerned chunks got backupped already.

	var cmin_x = rect_origin_x / HTerrain.CHUNK_SIZE
	var cmin_y = rect_origin_y / HTerrain.CHUNK_SIZE
	var cmax_x = (rect_origin_x + rect_size_x - 1) / HTerrain.CHUNK_SIZE + 1
	var cmax_y = (rect_origin_y + rect_size_y - 1) / HTerrain.CHUNK_SIZE + 1

	for cpos_y in range(cmin_y, cmax_y):
		var min_y = cpos_y * HTerrain.CHUNK_SIZE
		var max_y = min_y + HTerrain.CHUNK_SIZE
			
		for cpos_x in range(cmin_x, cmax_x):
		
			var k = Util.encode_v2i(cpos_x, cpos_y)
			if undo_cache.has(k):
				# Already backupped
				continue

			var min_x = cpos_x * HTerrain.CHUNK_SIZE
			var max_x = min_x + HTerrain.CHUNK_SIZE

			var invalid_min = not is_valid_pos(min_x, min_y, im)
			var invalid_max = not is_valid_pos(max_x - 1, max_y - 1, im) # Note: max is excluded

			if invalid_min or invalid_max:
				# Out of bounds

				# Note: this error check isn't working because data grids are intentionally off-by-one
				#if(invalid_min ^ invalid_max)
				#	print_line("Wut? Grid might not be multiple of chunk size!");

				continue

			var sub_image = im.get_rect(Rect2(min_x, min_y, max_x - min_x, max_y - min_y))
			undo_cache[k] = sub_image



func paint_height(data, origin_x, origin_y, speed):

	var im = data.get_image(HTerrainData.CHANNEL_HEIGHT)
	assert(im != null)

	backup_for_undo(im, _undo_cache, origin_x, origin_y, _shape_size, _shape_size)

	im.lock()
	var op = OperatorAdd.new(im)
	foreach_xy(op, data, origin_x, origin_y, speed, _opacity, _shape)
	im.unlock()

	data.update_normals(origin_x, origin_y, _shape_size, _shape_size)

	
func smooth_height(data, origin_x, origin_y, speed):

	var im = data.get_image(HTerrainData.CHANNEL_HEIGHT)
	assert(im != null)

	backup_for_undo(im, _undo_cache, origin_x, origin_y, _shape_size, _shape_size)

	im.lock()

	var sum_op = OperatorSum.new(im)
	foreach_xy(sum_op, data, origin_x, origin_y, 1.0, _opacity, _shape)
	var target_value = sum_op.sum / float(_shape_sum)

	var lerp_op = OperatorLerp.new(target_value, im)
	foreach_xy(lerp_op, data, origin_x, origin_y, speed, _opacity, _shape)
	
	im.unlock()

	data.update_normals(origin_x, origin_y, _shape_size, _shape_size)


func flatten_height(data, origin_x, origin_y):

	var im = data.get_image(HTerrainData.CHANNEL_HEIGHT)
	assert(im != null)

	backup_for_undo(im, _undo_cache, origin_x, origin_y, _shape_size, _shape_size)

	im.lock()
	var op = OperatorLerp.new(_flatten_height, im)
	foreach_xy(op, data, origin_x, origin_y, 1, 1, _shape)
	im.unlock()

	data.update_normals(origin_x, origin_y, _shape_size, _shape_size)


func paint_splat(data, origin_x, origin_y):

	var im = data.get_image(HTerrainData.CHANNEL_SPLAT)
	assert(im != null)

	var shape_size = _shape_size

	backup_for_undo(im, _undo_cache, origin_x, origin_y, shape_size, shape_size)

	var min_x = origin_x
	var min_y = origin_y
	var max_x = min_x + shape_size
	var max_y = min_y + shape_size
	var min_noclamp_x = min_x
	var min_noclamp_y = min_y

	var pmin = [min_x, min_y]
	var pmax = [max_x, max_y]
	Util.clamp_min_max_excluded(pmin, pmax, [0, 0], [data.get_resolution(), data.get_resolution()])
	min_x = pmin[0]
	min_y = pmin[1]
	max_x = pmax[0]
	max_y = pmax[1]
	
	im.lock()
	
	if _texture_mode == HTerrain.SHADER_SIMPLE4:
		
		var target_color = Color(0, 0, 0, 0)
		target_color[_texture_index] = 1.0
		
		for y in range(min_y, max_y):
			var py = y - min_noclamp_y
			
			for x in range(min_x, max_x):
				var px = x - min_noclamp_x
				
				var shape_value = _shape[py][px]
	
				var c = im.get_pixel(x, y)
				c = c.linear_interpolate(target_color, shape_value * _opacity)
				im.set_pixel(x, y, c)

	
#	elif _texture_mode == HTerrain.SHADER_ARRAY:
#		var shape_threshold = 0.1
#
#		for y in range(min_y, max_y):
#			var py = y - min_noclamp_y
#
#			for x in range(min_x, max_x):
#				var px = x - min_noclamp_x
#
#				var shape_value = _shape[py][px]
#
#				if shape_value > shape_threshold:
#					# TODO Improve weight blending, it looks meh
#					var c = Color()
#					c.r = float(_texture_index) / 256.0
#					c.g = clamp(_opacity, 0.0, 1.0)
#					im.set_pixel(x, y, c)
	else:
		print("Unknown texture mode ", _texture_mode)

	im.unlock()


func paint_color(data, origin_x, origin_y):

	var im = data.get_image(HTerrainData.CHANNEL_COLOR)
	assert(im != null)

	backup_for_undo(im, _undo_cache, origin_x, origin_y, _shape_size, _shape_size)

	im.lock()
	var op = OperatorLerpColor.new(_color, im)
	foreach_xy(op, data, origin_x, origin_y, 1, _opacity, _shape)
	im.unlock()


func paint_mask(data, origin_x, origin_y):

	var im = data.get_image(HTerrainData.CHANNEL_MASK)
	assert(im != null)
	
	backup_for_undo(im, _undo_cache, origin_x, origin_y, _shape_size, _shape_size);

	var shape_size = _shape_size

	var min_x = origin_x
	var min_y = origin_y
	var max_x = min_x + shape_size
	var max_y = min_y + shape_size
	var min_noclamp_x = min_x
	var min_noclamp_y = min_y

	var pmin = [min_x, min_y]
	var pmax = [max_x, max_y]
	Util.clamp_min_max_excluded(pmin, pmax, [0, 0], [data.get_resolution(), data.get_resolution()])
	min_x = pmin[0]
	min_y = pmin[1]
	max_x = pmax[0]
	max_y = pmax[1]

	var shape_threshold = 0.1
	var value = Color(1.0, 0.0, 0.0, 0.0) if _opacity > 0.5 else Color()

	im.lock()

	for y in range(min_y, max_y):
		for x in range(min_x, max_x):

			var px = x - min_noclamp_x
			var py = y - min_noclamp_y
			
			var shape_value = _shape[py][px]

			if shape_value > shape_threshold:
				im.set_pixel(x, y, value)


static func fetch_redo_chunks(im, keys):
	var output = []
	for key in keys:
		var cpos = Util.decode_v2i(key)
		var min_x = cpos[0] * HTerrain.CHUNK_SIZE
		var min_y = cpos[1] * HTerrain.CHUNK_SIZE
		var max_x = min_x + 1 * HTerrain.CHUNK_SIZE
		var max_y = min_y + 1 * HTerrain.CHUNK_SIZE
		var sub_image = im.get_rect(Rect2(min_x, min_y, max_x - min_x, max_y - min_y))
		output.append(sub_image)
	return output


func _edit_pop_undo_redo_data(heightmap_data):

	# TODO If possible, use a custom Reference class to store this data into the UndoRedo API,
	# but WITHOUT exposing it to scripts (so we won't need the following conversions!)

	var chunk_positions_keys = _undo_cache.keys()

	var channel = get_mode_channel(_mode)
	assert(channel != HTerrainData.CHANNEL_COUNT)

	var im = heightmap_data.get_image(channel)
	assert(im != null)
	
	var redo_data = fetch_redo_chunks(im, chunk_positions_keys)

	# Convert chunk positions to flat int array
	var undo_data = []
	var chunk_positions = PoolIntArray()
	chunk_positions.resize(chunk_positions_keys.size() * 2)
	
	var i = 0
	for key in chunk_positions_keys:
		var cpos = Util.decode_v2i(key)
		chunk_positions[i] = cpos[0]
		chunk_positions[i + 1] = cpos[1]
		i += 2
		# Also gather pre-cached data for undo, in the same order
		undo_data.append(_undo_cache[key])

	var data = {
		"undo": undo_data,
		"redo": redo_data,
		"chunk_positions": chunk_positions,
		"channel": channel
	}

	_undo_cache.clear()

	return data

