package systray

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "shared:dbus"

DBUSMENU_INTERFACE :: "com.canonical.dbusmenu"
DBUSMENU_VERSION :: u32(3)

@(private = "file")
DBUSMENU_INTROSPECT_XML := #load("dbus-dbusmenu.xml")

MenuActivateCallback :: #type proc(menu: ^Menu, id: i32, userdata: rawptr)
MenuAboutToShowCallback :: #type proc(menu: ^Menu, id: i32, userdata: rawptr) -> bool

ItemType :: enum {
	Standard,
	Separator,
}

ToggleType :: enum {
	None,
	Checkmark,
	Radio,
}

ToggleState :: enum i32 {
	Off           = 0,
	On            = 1,
	Indeterminate = -1,
}

Disposition :: enum {
	Normal,
	Informative,
	Warning,
	Alert,
}

MenuItem :: struct {
	type:         ItemType,
	label:        string,
	disabled:     bool,
	hidden:       bool,
	toggle_type:  ToggleType,
	toggle_state: ToggleState,
	disposition:  Disposition,
}

@(private = "file")
MenuNode :: struct {
	parent:     i32,
	children:   [dynamic]i32,
	using item: MenuItem,
}

Menu :: struct {
	connection:       ^dbus.Connection,
	object_path:      cstring,
	items:            map[i32]MenuNode,
	next_id:          i32,
	revision:         u32,
	activate_cb:      MenuActivateCallback,
	about_to_show_cb: MenuAboutToShowCallback,
	userdata:         rawptr,
	allocator:        runtime.Allocator,
	odin_ctx:         runtime.Context,
}

menu_init :: proc(
	menu: ^Menu,
	conn: ^dbus.Connection,
	object_path: string,
	allocator := context.allocator,
) -> bool {
	menu.connection = conn
	menu.object_path = strings.clone_to_cstring(object_path, allocator)
	menu.items = make(map[i32]MenuNode, 16, allocator)
	menu.next_id = 1
	menu.revision = 1
	menu.allocator = allocator
	menu.odin_ctx = context

	menu.items[0] = MenuNode {
		children = make([dynamic]i32, allocator),
	}

	err: dbus.Error
	dbus.error_init(&err)
	register_ok := dbus.connection_try_register_object_path(
		menu.connection,
		menu.object_path,
		&{message_function = menu_message_handler},
		menu,
		&err,
	)
	if dbus.error_is_set(&err) {
		log.errorf("register failed: %s - %s", err.name, err.message)
		dbus.error_free(&err)
		menu_deinit(menu)
		return false
	}
	if !register_ok {
		log.errorf("could not register object path %s", object_path)
		menu_deinit(menu)
		return false
	}
	return true
}

menu_deinit :: proc(menu: ^Menu) {
	if menu.connection != nil && menu.object_path != "" {
		dbus.connection_unregister_object_path(menu.connection, menu.object_path)
	}
	for _, &node in menu.items {
		if len(node.label) > 0 do delete(node.label, menu.allocator)
		delete(node.children)
	}
	delete(menu.items)
	if menu.object_path != "" do delete(menu.object_path, menu.allocator)
	menu^ = {}
}

menu_add_item :: proc(menu: ^Menu, parent_id: i32, item: MenuItem) -> (id: i32) {
	if _, exists := menu.items[parent_id]; !exists do return 0

	id = menu.next_id
	menu.next_id += 1

	node := MenuNode {
		parent   = parent_id,
		children = make([dynamic]i32, menu.allocator),
		item     = item,
	}
	if len(item.label) > 0 do node.label = strings.clone(item.label, menu.allocator)
	menu.items[id] = node

	parent_node := &menu.items[parent_id]
	append(&parent_node.children, id)

	emit_layout_updated(menu, parent_id)
	return id
}

menu_remove_item :: proc(menu: ^Menu, id: i32) {
	if id == 0 do return

	parent_id: i32
	children_copy: []i32
	{
		node, exists := menu.items[id]
		if !exists do return
		parent_id = node.parent
		children_copy = slice.clone(node.children[:], context.temp_allocator)
	}

	for child_id in children_copy do menu_remove_item(menu, child_id)

	if parent_node, ok := &menu.items[parent_id]; ok {
		for cid, idx in parent_node.children {
			if cid == id {
				ordered_remove(&parent_node.children, idx)
				break
			}
		}
	}

	if node, ok := &menu.items[id]; ok {
		if len(node.label) > 0 do delete(node.label, menu.allocator)
		delete(node.children)
	}
	delete_key(&menu.items, id)

	emit_layout_updated(menu, parent_id)
}

menu_clear :: proc(menu: ^Menu) {
	root, found := menu.items[0]
	if !found do return
	children_copy := slice.clone(root.children[:], context.temp_allocator)
	for child_id in children_copy do menu_remove_item(menu, child_id)
}

menu_set_label :: proc(menu: ^Menu, id: i32, label: string) {
	node, ok := &menu.items[id]
	if !ok do return
	if node.label == label do return
	if len(node.label) > 0 do delete(node.label, menu.allocator)
	node.label = len(label) > 0 ? strings.clone(label, menu.allocator) : ""
	emit_items_properties_updated(menu, {id}, {"label"})
}

menu_set_enabled :: proc(menu: ^Menu, id: i32, enabled: bool) {
	node, ok := &menu.items[id]
	if !ok do return
	if node.disabled == !enabled do return
	node.disabled = !enabled
	emit_items_properties_updated(menu, {id}, {"enabled"})
}

menu_set_visible :: proc(menu: ^Menu, id: i32, visible: bool) {
	node, ok := &menu.items[id]
	if !ok do return
	if node.hidden == !visible do return
	node.hidden = !visible
	emit_items_properties_updated(menu, {id}, {"visible"})
}

menu_set_toggle_state :: proc(menu: ^Menu, id: i32, state: ToggleState) {
	node, ok := &menu.items[id]
	if !ok do return
	if node.toggle_state == state do return
	node.toggle_state = state
	emit_items_properties_updated(menu, {id}, {"toggle-state"})
}

@(private = "file")
item_type_str :: proc(t: ItemType) -> string {
	switch t {
	case .Separator:
		return "separator"
	case .Standard:
		return "standard"
	}
	return "standard"
}

@(private = "file")
toggle_type_str :: proc(t: ToggleType) -> string {
	switch t {
	case .Checkmark:
		return "checkmark"
	case .Radio:
		return "radio"
	case .None:
		return ""
	}
	return ""
}

@(private = "file")
disposition_str :: proc(d: Disposition) -> string {
	switch d {
	case .Informative:
		return "informative"
	case .Warning:
		return "warning"
	case .Alert:
		return "alert"
	case .Normal:
		return "normal"
	}
	return "normal"
}

@(private = "file")
emit_layout_updated :: proc(menu: ^Menu, parent: i32) {
	menu.revision += 1
	msg := dbus.message_new_signal(menu.object_path, DBUSMENU_INTERFACE, "LayoutUpdated")
	if msg == nil {
		log.warn("could not allocate LayoutUpdated signal")
		return
	}
	defer dbus.message_unref(msg)

	payload := struct {
		revision: u32,
		parent:   i32,
	}{menu.revision, parent}
	if dbus.marshal(msg, payload) != nil {
		log.warn("failed to marshal LayoutUpdated payload")
		return
	}
	if !dbus.connection_send(menu.connection, msg, nil) {
		log.warn("failed to send LayoutUpdated signal")
	}
}

@(private = "file")
emit_items_properties_updated :: proc(menu: ^Menu, ids: []i32, filter: []string) {
	msg := dbus.message_new_signal(menu.object_path, DBUSMENU_INTERFACE, "ItemsPropertiesUpdated")
	if msg == nil {
		log.warn("could not allocate ItemsPropertiesUpdated signal")
		return
	}
	defer dbus.message_unref(msg)

	it: dbus.MessageIter
	dbus.message_iter_init_append(msg, &it)

	updated_arr: dbus.MessageIter
	if !dbus.message_iter_open_container(&it, .ARRAY, "(ia{sv})", &updated_arr) {
		log.warn("open updated_arr failed")
		return
	}
	for id in ids {
		node, ok := &menu.items[id]
		if !ok do continue

		entry: dbus.MessageIter
		if !dbus.message_iter_open_container(&updated_arr, .STRUCT, nil, &entry) do continue
		iv := id
		dbus.message_iter_append_basic(&entry, .INT32, &iv)
		write_item_properties(&entry, node, filter)
		dbus.message_iter_close_container(&updated_arr, &entry)
	}
	dbus.message_iter_close_container(&it, &updated_arr)

	removed_arr: dbus.MessageIter
	dbus.message_iter_open_container(&it, .ARRAY, "(ias)", &removed_arr)
	dbus.message_iter_close_container(&it, &removed_arr)

	if !dbus.connection_send(menu.connection, msg, nil) {
		log.warn("failed to send ItemsPropertiesUpdated signal")
	}
}

@(private = "file")
include_prop :: proc(filter: []string, name: string) -> bool {
	if len(filter) == 0 do return true
	for f in filter do if f == name do return true
	return false
}

@(private = "file")
write_item_properties :: proc(parent_iter: ^dbus.MessageIter, node: ^MenuNode, filter: []string) {
	arr: dbus.MessageIter
	dbus.message_iter_open_container(parent_iter, .ARRAY, "{sv}", &arr)

	if include_prop(filter, "type") && node.type != .Standard {
		dict_write_string(&arr, "type", item_type_str(node.type))
	}
	if include_prop(filter, "label") && len(node.label) > 0 {
		dict_write_string(&arr, "label", node.label)
	}
	if include_prop(filter, "enabled") && node.disabled {
		dict_write_bool(&arr, "enabled", false)
	}
	if include_prop(filter, "visible") && node.hidden {
		dict_write_bool(&arr, "visible", false)
	}
	if include_prop(filter, "toggle-type") && node.toggle_type != .None {
		dict_write_string(&arr, "toggle-type", toggle_type_str(node.toggle_type))
	}
	if include_prop(filter, "toggle-state") && node.toggle_type != .None {
		dict_write_int(&arr, "toggle-state", i32(node.toggle_state))
	}
	if include_prop(filter, "disposition") && node.disposition != .Normal {
		dict_write_string(&arr, "disposition", disposition_str(node.disposition))
	}
	if include_prop(filter, "children-display") && len(node.children) > 0 {
		dict_write_string(&arr, "children-display", "submenu")
	}

	dbus.message_iter_close_container(parent_iter, &arr)
}

@(private = "file")
dict_write_string :: proc(arr: ^dbus.MessageIter, name, value: string) {
	entry: dbus.MessageIter
	dbus.message_iter_open_container(arr, .DICT_ENTRY, nil, &entry)

	name_cs := strings.clone_to_cstring(name, context.temp_allocator)
	dbus.message_iter_append_basic(&entry, .STRING, &name_cs)

	var_it: dbus.MessageIter
	dbus.message_iter_open_container(&entry, .VARIANT, "s", &var_it)
	val_cs := strings.clone_to_cstring(value, context.temp_allocator)
	dbus.message_iter_append_basic(&var_it, .STRING, &val_cs)
	dbus.message_iter_close_container(&entry, &var_it)

	dbus.message_iter_close_container(arr, &entry)
}

@(private = "file")
dict_write_bool :: proc(arr: ^dbus.MessageIter, name: string, value: bool) {
	entry: dbus.MessageIter
	dbus.message_iter_open_container(arr, .DICT_ENTRY, nil, &entry)

	name_cs := strings.clone_to_cstring(name, context.temp_allocator)
	dbus.message_iter_append_basic(&entry, .STRING, &name_cs)

	var_it: dbus.MessageIter
	dbus.message_iter_open_container(&entry, .VARIANT, "b", &var_it)
	bv := dbus.bool_t(value)
	dbus.message_iter_append_basic(&var_it, .BOOLEAN, &bv)
	dbus.message_iter_close_container(&entry, &var_it)

	dbus.message_iter_close_container(arr, &entry)
}

@(private = "file")
dict_write_int :: proc(arr: ^dbus.MessageIter, name: string, value: i32) {
	entry: dbus.MessageIter
	dbus.message_iter_open_container(arr, .DICT_ENTRY, nil, &entry)

	name_cs := strings.clone_to_cstring(name, context.temp_allocator)
	dbus.message_iter_append_basic(&entry, .STRING, &name_cs)

	var_it: dbus.MessageIter
	dbus.message_iter_open_container(&entry, .VARIANT, "i", &var_it)
	iv := value
	dbus.message_iter_append_basic(&var_it, .INT32, &iv)
	dbus.message_iter_close_container(&entry, &var_it)

	dbus.message_iter_close_container(arr, &entry)
}

@(private = "file")
write_layout :: proc(
	parent_iter: ^dbus.MessageIter,
	menu: ^Menu,
	id: i32,
	depth_remaining: i32,
	filter: []string,
) {
	node, ok := &menu.items[id]
	if !ok do return

	s_iter: dbus.MessageIter
	dbus.message_iter_open_container(parent_iter, .STRUCT, nil, &s_iter)

	iv := id
	dbus.message_iter_append_basic(&s_iter, .INT32, &iv)

	write_item_properties(&s_iter, node, filter)

	children_iter: dbus.MessageIter
	dbus.message_iter_open_container(&s_iter, .ARRAY, "v", &children_iter)
	if depth_remaining != 0 {
		next_depth := depth_remaining < 0 ? -1 : depth_remaining - 1
		for child_id in node.children {
			v_iter: dbus.MessageIter
			dbus.message_iter_open_container(&children_iter, .VARIANT, "(ia{sv}av)", &v_iter)
			write_layout(&v_iter, menu, child_id, next_depth, filter)
			dbus.message_iter_close_container(&children_iter, &v_iter)
		}
	}
	dbus.message_iter_close_container(&s_iter, &children_iter)
	dbus.message_iter_close_container(parent_iter, &s_iter)
}

@(private = "file")
handle_menu_introspect :: proc(conn: ^dbus.Connection, msg: ^dbus.Message) -> dbus.HandlerResult {
	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	if dbus.marshal(reply, string(DBUSMENU_INTROSPECT_XML)) != nil do return .NEED_MEMORY
	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
MenuProperties :: struct {
	version:         u32 `dbus_name:"Version"`,
	text_direction:  string `dbus_name:"TextDirection"`,
	status:          string `dbus_name:"Status"`,
	icon_theme_path: []string `dbus_name:"IconThemePath"`,
}

@(private = "file")
handle_menu_get_all :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	GetAllReply :: struct {
		properties: MenuProperties `dbus:"a{sv}"`,
	}
	payload := GetAllReply {
		properties = {
			version = DBUSMENU_VERSION,
			text_direction = "ltr",
			status = "normal",
			icon_theme_path = {},
		},
	}
	if dbus.marshal(reply, payload) != nil do return .NOT_YET_HANDLED
	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
handle_menu_property_get :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	args: struct {
		iface: string,
		name:  string,
	}
	if dbus.unmarshal(msg, &args, context.temp_allocator) != nil do return .NOT_YET_HANDLED

	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	it: dbus.MessageIter
	dbus.message_iter_init_append(reply, &it)

	switch args.name {
	case "Version":
		var_it: dbus.MessageIter
		dbus.message_iter_open_container(&it, .VARIANT, "u", &var_it)
		v := DBUSMENU_VERSION
		dbus.message_iter_append_basic(&var_it, .UINT32, &v)
		dbus.message_iter_close_container(&it, &var_it)
	case "TextDirection":
		write_top_variant_string(&it, "ltr")
	case "Status":
		write_top_variant_string(&it, "normal")
	case "IconThemePath":
		var_it: dbus.MessageIter
		dbus.message_iter_open_container(&it, .VARIANT, "as", &var_it)
		a_it: dbus.MessageIter
		dbus.message_iter_open_container(&var_it, .ARRAY, "s", &a_it)
		dbus.message_iter_close_container(&var_it, &a_it)
		dbus.message_iter_close_container(&it, &var_it)
	case:
		return .NOT_YET_HANDLED
	}

	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
write_top_variant_string :: proc(it: ^dbus.MessageIter, value: string) {
	var_it: dbus.MessageIter
	dbus.message_iter_open_container(it, .VARIANT, "s", &var_it)
	cs := strings.clone_to_cstring(value, context.temp_allocator)
	dbus.message_iter_append_basic(&var_it, .STRING, &cs)
	dbus.message_iter_close_container(it, &var_it)
}

@(private = "file")
write_top_variant_bool :: proc(it: ^dbus.MessageIter, value: bool) {
	var_it: dbus.MessageIter
	dbus.message_iter_open_container(it, .VARIANT, "b", &var_it)
	bv := dbus.bool_t(value)
	dbus.message_iter_append_basic(&var_it, .BOOLEAN, &bv)
	dbus.message_iter_close_container(it, &var_it)
}

@(private = "file")
write_top_variant_int :: proc(it: ^dbus.MessageIter, value: i32) {
	var_it: dbus.MessageIter
	dbus.message_iter_open_container(it, .VARIANT, "i", &var_it)
	iv := value
	dbus.message_iter_append_basic(&var_it, .INT32, &iv)
	dbus.message_iter_close_container(it, &var_it)
}

@(private = "file")
handle_get_layout :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	args: struct {
		parent_id: i32,
		depth:     i32,
		filter:    []string,
	}
	if dbus.unmarshal(msg, &args, context.temp_allocator) != nil do return .NOT_YET_HANDLED

	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	it: dbus.MessageIter
	dbus.message_iter_init_append(reply, &it)

	rev := menu.revision
	dbus.message_iter_append_basic(&it, .UINT32, &rev)

	write_layout(&it, menu, args.parent_id, args.depth, args.filter)

	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
handle_get_group_properties :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	args: struct {
		ids:    []i32,
		filter: []string,
	}
	if dbus.unmarshal(msg, &args, context.temp_allocator) != nil do return .NOT_YET_HANDLED

	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	it: dbus.MessageIter
	dbus.message_iter_init_append(reply, &it)

	arr: dbus.MessageIter
	dbus.message_iter_open_container(&it, .ARRAY, "(ia{sv})", &arr)
	for id in args.ids {
		node, ok := &menu.items[id]
		if !ok do continue

		entry: dbus.MessageIter
		dbus.message_iter_open_container(&arr, .STRUCT, nil, &entry)
		iv := id
		dbus.message_iter_append_basic(&entry, .INT32, &iv)
		write_item_properties(&entry, node, args.filter)
		dbus.message_iter_close_container(&arr, &entry)
	}
	dbus.message_iter_close_container(&it, &arr)

	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
handle_get_property :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	args: struct {
		id:   i32,
		name: string,
	}
	if dbus.unmarshal(msg, &args, context.temp_allocator) != nil do return .NOT_YET_HANDLED

	node, ok := &menu.items[args.id]
	if !ok do return .NOT_YET_HANDLED

	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	it: dbus.MessageIter
	dbus.message_iter_init_append(reply, &it)

	switch args.name {
	case "type":
		write_top_variant_string(&it, item_type_str(node.type))
	case "label":
		write_top_variant_string(&it, node.label)
	case "enabled":
		write_top_variant_bool(&it, !node.disabled)
	case "visible":
		write_top_variant_bool(&it, !node.hidden)
	case "toggle-type":
		write_top_variant_string(&it, toggle_type_str(node.toggle_type))
	case "toggle-state":
		write_top_variant_int(&it, i32(node.toggle_state))
	case "disposition":
		write_top_variant_string(&it, disposition_str(node.disposition))
	case "children-display":
		cd: string
		if len(node.children) > 0 do cd = "submenu"
		write_top_variant_string(&it, cd)
	case:
		return .NOT_YET_HANDLED
	}

	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
dispatch_event :: proc(menu: ^Menu, id: i32, event_id: string) {
	if event_id != "clicked" do return
	if menu.activate_cb != nil do menu.activate_cb(menu, id, menu.userdata)
}

@(private = "file")
handle_event :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	it: dbus.MessageIter
	if !dbus.message_iter_init(msg, &it) do return .NOT_YET_HANDLED

	bv: dbus.BasicValue
	dbus.message_iter_get_basic(&it, &bv)
	id := bv.int32
	dbus.message_iter_next(&it)

	dbus.message_iter_get_basic(&it, &bv)
	event_id := string(bv.str)
	dbus.message_iter_next(&it)

	dbus.message_iter_next(&it)

	dbus.message_iter_get_basic(&it, &bv)
	_ = bv.uint32

	dispatch_event(menu, id, event_id)
	return send_empty_reply(conn, msg)
}

@(private = "file")
handle_event_group :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	it: dbus.MessageIter
	if !dbus.message_iter_init(msg, &it) do return .NOT_YET_HANDLED

	arr: dbus.MessageIter
	dbus.message_iter_recurse(&it, &arr)

	for dbus.message_iter_get_arg_type(&arr) != .INVALID {
		entry: dbus.MessageIter
		dbus.message_iter_recurse(&arr, &entry)

		bv: dbus.BasicValue
		dbus.message_iter_get_basic(&entry, &bv)
		id := bv.int32
		dbus.message_iter_next(&entry)

		dbus.message_iter_get_basic(&entry, &bv)
		event_id := string(bv.str)
		dbus.message_iter_next(&entry)

		dbus.message_iter_next(&entry)

		dbus.message_iter_get_basic(&entry, &bv)
		_ = bv.uint32

		dispatch_event(menu, id, event_id)

		dbus.message_iter_next(&arr)
	}

	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	rit: dbus.MessageIter
	dbus.message_iter_init_append(reply, &rit)
	rarr: dbus.MessageIter
	dbus.message_iter_open_container(&rit, .ARRAY, "i", &rarr)
	dbus.message_iter_close_container(&rit, &rarr)

	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
handle_about_to_show :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	id: i32
	if dbus.unmarshal(msg, &id, context.temp_allocator) != nil do return .NOT_YET_HANDLED

	need_update := false
	if menu.about_to_show_cb != nil do need_update = menu.about_to_show_cb(menu, id, menu.userdata)

	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	if dbus.marshal(reply, need_update) != nil do return .NEED_MEMORY
	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
handle_about_to_show_group :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	menu: ^Menu,
) -> dbus.HandlerResult {
	ids: []i32
	if dbus.unmarshal(msg, &ids, context.temp_allocator) != nil do return .NOT_YET_HANDLED

	updates_needed := make([dynamic]i32, context.temp_allocator)
	if menu.about_to_show_cb != nil {
		for id in ids {
			if menu.about_to_show_cb(menu, id, menu.userdata) do append(&updates_needed, id)
		}
	}

	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	payload := struct {
		updates_needed: []i32,
		id_errors:      []i32,
	}{updates_needed[:], {}}
	if dbus.marshal(reply, payload) != nil do return .NOT_YET_HANDLED
	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
menu_message_handler :: proc "c" (
	connection: ^dbus.Connection,
	msg: ^dbus.Message,
	userdata: rawptr,
) -> dbus.HandlerResult {
	menu := (^Menu)(userdata)
	context = menu.odin_ctx

	iface := string(dbus.message_get_interface(msg))
	member := string(dbus.message_get_member(msg))

	switch iface {
	case DBUS_INTROSPECTABLE_INTERFACE:
		if member == "Introspect" do return handle_menu_introspect(connection, msg)
	case DBUS_PROPERTIES_INTERFACE:
		switch member {
		case "GetAll":
			return handle_menu_get_all(connection, msg, menu)
		case "Get":
			return handle_menu_property_get(connection, msg, menu)
		}
	case DBUSMENU_INTERFACE:
		switch member {
		case "GetLayout":
			return handle_get_layout(connection, msg, menu)
		case "GetGroupProperties":
			return handle_get_group_properties(connection, msg, menu)
		case "GetProperty":
			return handle_get_property(connection, msg, menu)
		case "Event":
			return handle_event(connection, msg, menu)
		case "EventGroup":
			return handle_event_group(connection, msg, menu)
		case "AboutToShow":
			return handle_about_to_show(connection, msg, menu)
		case "AboutToShowGroup":
			return handle_about_to_show_group(connection, msg, menu)
		}
	}
	return .NOT_YET_HANDLED
}
