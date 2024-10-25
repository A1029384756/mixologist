package pipewire

import "core:fmt"
import "core:strings"

foreign import pipewire "system:pipewire-0.3"

@(default_calling_convention = "c", link_prefix = "pw_")
foreign pipewire {
	init :: proc(argc: ^int, argv: [^]cstring) ---
	deinit :: proc() ---
	get_library_version :: proc() -> cstring ---
	get_client_name :: proc() -> cstring ---
	properties_new :: proc(key: cstring, #c_vararg args: ..any) -> ^pw_properties ---
	properties_free :: proc(props: ^pw_properties) ---
	properties_set :: proc(properties: ^pw_properties, key: cstring, value: cstring) -> int ---
	properties_update_string :: proc(props: ^pw_properties, str: cstring, size: uint) -> int ---
	main_loop_new :: proc(props: ^spa_dict) -> ^pw_main_loop ---
	main_loop_destroy :: proc(loop: ^pw_main_loop) ---
	main_loop_get_loop :: proc(loop: ^pw_main_loop) -> ^pw_loop ---
	main_loop_quit :: proc(loop: ^pw_main_loop) -> int ---
	main_loop_run :: proc(loop: ^pw_main_loop) -> int ---
	context_new :: proc(main_loop: ^pw_loop, props: ^pw_properties, user_data_size: uint) -> ^pw_context ---
	context_destroy :: proc(ctx: ^pw_context) ---
	context_load_module :: proc(ctx: ^pw_context, name: cstring, args: cstring, properties: ^pw_properties) -> ^pw_impl_module ---
	impl_module_add_listener :: proc(module: ^pw_impl_module, listener: ^spa_hook, events: ^pw_impl_module_events, data: rawptr) ---
	impl_module_get_info :: proc(module: ^pw_impl_module) -> ^pw_module_info ---
	stream_set_control :: proc(stream: ^pw_stream, id: u32, n_values: u32, values: ^f32, #c_vararg args: ..any) -> int ---
	core_find_proxy :: proc(core: ^pw_core, id: u32) -> ^pw_proxy ---
	core_disconnect :: proc(core: ^pw_core) ---
	context_connect :: proc(ctx: ^pw_context, properties: ^pw_properties, user_data_size: uint) -> ^pw_core ---
	proxy_get_user_data :: proc(proxy: ^pw_proxy) -> rawptr ---
	proxy_add_listener :: proc(proxy: ^pw_proxy, listener: ^spa_hook, events: ^pw_proxy_events, data: rawptr) ---
	proxy_get_type :: proc(proxy: ^pw_proxy, version: u32) -> cstring ---
	proxy_destroy :: proc(proxy: ^pw_proxy) ---
	impl_metadata_set_property :: proc(metadata: ^pw_impl_metadata, subject: u32, key, type, value: cstring) -> int ---
	context_create_metadata :: proc(ctx: ^pw_context, name: cstring, properties: ^pw_properties, user_data_size: uint) -> ^pw_impl_metadata ---
	impl_metadata_get_properties :: proc(metadata: ^pw_impl_metadata) -> ^pw_properties ---
	impl_metadata_register :: proc(metadata: ^pw_impl_metadata, properties: ^pw_properties) -> int ---
	impl_metadata_destroy :: proc(metadata: ^pw_impl_metadata) ---
	impl_metadata_get_user_data :: proc(metadata: ^pw_impl_metadata) -> rawptr ---
	impl_metadata_get_global :: proc(metadata: ^pw_impl_metadata) -> ^pw_global ---
	impl_metadata_add_listener :: proc(metadata: ^pw_impl_metadata, listener: ^spa_hook, events: ^pw_impl_module_events, data: rawptr) ---
}

properties_update_cstring :: proc(props: ^pw_properties, str: cstring) {
	properties_update_string(props, str, len(str))
}

// this proc is incomplete and only handles the simple case of '"key": "value"'
properties_serialize_dict :: proc(sb: ^strings.Builder, dict: ^spa_dict) {
	for item, idx in dict.items[:dict.n_items] {
		fmt.sbprintf(sb, "%s", idx == 0 ? "" : ", ")
		fmt.sbprintf(sb, "\"%s\": \"%s\"", item.key, item.value)
	}
}

core_get_registry :: proc(core: ^pw_core, version: u32, user_data_size: uint) -> ^pw_registry {
	_f := cast(^pw_core_methods)((cast(^spa_interface)core).cb).funcs
	if _f != nil && _f.version >= PW_VERSION_CORE_METHODS && _f.get_registry != nil {
		return _f.get_registry((&(cast(^spa_interface)core).cb).data, version, user_data_size)
	} else {
		panic("could not get registry")
	}
}

core_create_object :: proc(
	core: ^pw_core,
	factory_name: cstring,
	type: cstring,
	version: u32,
	props: ^spa_dict,
	user_data_size: uint,
) -> ^pw_proxy {
	_f := cast(^pw_core_methods)((cast(^spa_interface)core).cb).funcs
	if _f != nil && _f.version >= PW_VERSION_CORE_METHODS && _f.create_object != nil {
		return(
			cast(^pw_proxy)_f.create_object(
				(&(cast(^spa_interface)core).cb).data,
				factory_name,
				type,
				version,
				props,
				user_data_size,
			) \
		)
	} else {
		panic("could not create object")
	}
}

core_sync :: proc(core: ^pw_core, core_id: u32, sync: int) -> int {
	_f := cast(^pw_core_methods)((cast(^spa_interface)core).cb).funcs
	if _f != nil && _f.version >= PW_VERSION_CORE_METHODS && _f.sync != nil {
		return _f.sync((&(cast(^spa_interface)core).cb).data, 0, sync)
	} else {
		panic("could not sync core")
	}
}

registry_add_listener :: proc(
	registry: ^pw_registry,
	listener: ^spa_hook,
	events: ^pw_registry_events,
	data: rawptr,
) {
	_f := cast(^pw_registry_methods)((cast(^spa_interface)registry).cb).funcs
	if _f != nil && _f.version >= PW_VERSION_REGISTRY_METHODS && _f.add_listener != nil {
		_f.add_listener((&(cast(^spa_interface)registry).cb).data, listener, events, data)
	} else {
		panic("could not add listener")
	}
}

registry_bind :: proc(
	registry: ^pw_registry,
	id: u32,
	type: cstring,
	version: u32,
	user_data_size: uint,
) -> ^pw_proxy {
	_f := cast(^pw_registry_methods)((cast(^spa_interface)registry).cb).funcs
	if _f != nil && _f.version >= PW_VERSION_REGISTRY_METHODS && _f.bind != nil {
		return(
			cast(^pw_proxy)_f.bind(
				(&(cast(^spa_interface)registry).cb).data,
				id,
				type,
				version,
				user_data_size,
			) \
		)
	} else {
		panic("could not bind registry")
	}
}

registry_destroy :: proc(registry: ^pw_registry, id: u32) -> int {
	_f := cast(^pw_registry_methods)((cast(^spa_interface)registry).cb).funcs
	if _f != nil && _f.version >= PW_VERSION_REGISTRY_METHODS && _f.destroy != nil {
		return _f.destroy((&(cast(^spa_interface)registry).cb).data, id)
	} else {
		panic("could not destroy")
	}
}

node_set_param :: proc(proxy: ^pw_proxy, param_id: spa_param_type, flags: u32, pod: ^spa_pod) {
	_f := cast(^pw_node_methods)((cast(^spa_interface)cast(^pw_node)proxy).cb).funcs
	if _f != nil && _f.version >= PW_VERSION_NODE_EVENTS && _f.set_param != nil {
		_f.set_param((cast(^spa_interface)cast(^pw_node)proxy).cb.data, u32(param_id), flags, pod)
	} else {
		panic("could not set param")
	}
}
