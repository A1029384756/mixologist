package pipewire

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

foreign import pipewire "system:pipewire-0.3"

@(default_calling_convention = "c", link_prefix = "pw_")
foreign pipewire {
	init :: proc(argc: ^int, argv: [^]cstring) ---
	deinit :: proc() ---
	get_library_version :: proc() -> cstring ---
	get_client_name :: proc() -> cstring ---

	properties_new :: proc(key: cstring, #c_vararg args: ..any) -> ^properties ---
	properties_free :: proc(props: ^properties) ---
	properties_set :: proc(properties: ^properties, key: cstring, value: cstring) -> int ---
	properties_update_string :: proc(props: ^properties, str: cstring, size: uint) -> int ---

	main_loop_new :: proc(props: ^spa_dict) -> ^main_loop ---
	main_loop_destroy :: proc(loop: ^main_loop) ---
	main_loop_get_loop :: proc(main_loop: ^main_loop) -> ^loop ---
	main_loop_quit :: proc(loop: ^main_loop) -> int ---
	main_loop_run :: proc(loop: ^main_loop) -> int ---

	thread_loop_new :: proc(name: cstring, props: ^spa_dict) -> ^thread_loop ---
	thread_loop_new_full :: proc(loop: ^loop, name: cstring, props: ^spa_dict) -> ^thread_loop ---
	thread_loop_destroy :: proc(loop: ^thread_loop) ---
	thread_loop_add_listener :: proc(loop: ^thread_loop, listener: ^spa_hook, events: ^thread_loop_events, data: rawptr) ---
	thread_loop_get_loop :: proc(t_loop: ^thread_loop) -> ^loop ---
	thread_loop_start :: proc(loop: ^thread_loop) -> int ---
	thread_loop_stop :: proc(loop: ^thread_loop) ---
	thread_loop_lock :: proc(loop: ^thread_loop) ---
	thread_loop_unlock :: proc(loop: ^thread_loop) ---
	thread_loop_wait :: proc(loop: ^thread_loop) ---
	thread_loop_timed_wait :: proc(loop: ^thread_loop, wait_max_sec: int) -> int ---
	thread_loop_get_time :: proc(loop: ^thread_loop, abstime: ^linux.Time_Spec, timeout: i64) -> int ---
	thread_loop_timed_wait_full :: proc(loop: ^thread_loop, abstime: ^linux.Time_Spec) -> int ---
	thread_loop_signal :: proc(loop: ^thread_loop, wait_for_accept: bool) ---
	thread_loop_accept :: proc(loop: ^thread_loop) ---
	thread_loop_in_thread :: proc(loop: ^thread_loop) -> bool ---

	context_new :: proc(main_loop: ^loop, props: ^properties, user_data_size: uint) -> ^pw_context ---
	context_destroy :: proc(ctx: ^pw_context) ---
	context_load_module :: proc(ctx: ^pw_context, name: cstring, args: cstring, properties: ^properties) -> ^impl_module ---
	context_connect :: proc(ctx: ^pw_context, properties: ^properties, user_data_size: uint) -> ^core ---
	context_create_metadata :: proc(ctx: ^pw_context, name: cstring, properties: ^properties, user_data_size: uint) -> ^impl_metadata ---

	impl_module_add_listener :: proc(module: ^impl_module, listener: ^spa_hook, events: ^impl_module_events, data: rawptr) ---
	impl_module_get_info :: proc(module: ^impl_module) -> ^module_info ---
	stream_set_control :: proc(stream: ^stream, id: u32, n_values: u32, values: ^f32, #c_vararg args: ..any) -> int ---

	core_find_proxy :: proc(core: ^core, id: u32) -> ^proxy ---
	core_disconnect :: proc(core: ^core) ---

	proxy_get_user_data :: proc(proxy: ^proxy) -> rawptr ---
	proxy_add_listener :: proc(proxy: ^proxy, listener: ^spa_hook, events: ^proxy_events, data: rawptr) ---
	proxy_get_type :: proc(proxy: ^proxy, version: u32) -> cstring ---
	proxy_destroy :: proc(proxy: ^proxy) ---

	impl_metadata_set_property :: proc(metadata: ^impl_metadata, subject: u32, key, type, value: cstring) -> int ---
	impl_metadata_get_properties :: proc(metadata: ^impl_metadata) -> ^properties ---
	impl_metadata_register :: proc(metadata: ^impl_metadata, properties: ^properties) -> int ---
	impl_metadata_destroy :: proc(metadata: ^impl_metadata) ---
	impl_metadata_get_user_data :: proc(metadata: ^impl_metadata) -> rawptr ---
	impl_metadata_get_global :: proc(metadata: ^impl_metadata) -> ^global ---
	impl_metadata_add_listener :: proc(metadata: ^impl_metadata, listener: ^spa_hook, events: ^impl_module_events, data: rawptr) ---
}

properties_update_cstring :: proc(props: ^properties, str: cstring) {
	properties_update_string(props, str, len(str))
}

// this proc is incomplete and only handles the simple case of '"key": "value"'
properties_serialize_dict :: proc(sb: ^strings.Builder, dict: ^spa_dict) {
	for item, idx in dict.items[:dict.n_items] {
		fmt.sbprintf(sb, "%s", idx == 0 ? "" : ", ")
		fmt.sbprintf(sb, "\"%s\": \"%s\"", item.key, item.value)
	}
}

core_get_registry :: proc(core: ^core, version: u32, user_data_size: c.uint) -> ^registry {
	_f := cast(^core_methods)((cast(^spa_interface)core).cb).funcs
	if _f != nil && _f.version >= VERSION_CORE_METHODS && _f.get_registry != nil {
		return _f.get_registry((&(cast(^spa_interface)core).cb).data, version, user_data_size)
	} else {
		panic("could not get registry")
	}
}

core_create_object :: proc(
	core: ^core,
	factory_name: cstring,
	type: cstring,
	version: u32,
	props: ^spa_dict,
	user_data_size: c.uint,
) -> ^proxy {
	_f := cast(^core_methods)((cast(^spa_interface)core).cb).funcs
	if _f != nil && _f.version >= VERSION_CORE_METHODS && _f.create_object != nil {
		return(
			cast(^proxy)_f.create_object(
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

core_sync :: proc(core: ^core, #any_int sync: c.int) -> c.int {
	_f := cast(^core_methods)((cast(^spa_interface)core).cb).funcs
	if _f != nil && _f.version >= VERSION_CORE_METHODS && _f.sync != nil {
		return _f.sync((&(cast(^spa_interface)core).cb).data, 0, sync)
	} else {
		panic("could not sync core")
	}
}

core_add_listener :: proc(
	core: ^core,
	listener: ^spa_hook,
	events: ^core_events,
	data: rawptr,
) -> c.int {
	_f := cast(^core_methods)((cast(^spa_interface)core).cb).funcs
	if _f != nil && _f.version >= VERSION_CORE_METHODS && _f.add_listener != nil {
		return _f.add_listener((&(cast(^spa_interface)core).cb).data, listener, events, data)
	} else {
		panic("could not add listener")
	}
}

registry_add_listener :: proc(
	registry: ^registry,
	listener: ^spa_hook,
	events: ^registry_events,
	data: rawptr,
) {
	_f := cast(^registry_methods)((cast(^spa_interface)registry).cb).funcs
	if _f != nil && _f.version >= VERSION_REGISTRY_METHODS && _f.add_listener != nil {
		_f.add_listener((&(cast(^spa_interface)registry).cb).data, listener, events, data)
	} else {
		panic("could not add listener")
	}
}

registry_bind :: proc(
	registry: ^registry,
	id: u32,
	type: cstring,
	version: u32,
	user_data_size: uint,
) -> ^proxy {
	_f := cast(^registry_methods)((cast(^spa_interface)registry).cb).funcs
	if _f != nil && _f.version >= VERSION_REGISTRY_METHODS && _f.bind != nil {
		return(
			cast(^proxy)_f.bind(
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

registry_destroy :: proc(registry: ^registry, id: u32) -> c.int {
	_f := cast(^registry_methods)((cast(^spa_interface)registry).cb).funcs
	if _f != nil && _f.version >= VERSION_REGISTRY_METHODS && _f.destroy != nil {
		return _f.destroy((&(cast(^spa_interface)registry).cb).data, id)
	} else {
		panic("could not destroy")
	}
}

node_set_param :: proc(proxy: ^proxy, param_id: spa_param_type, flags: u32, pod: ^spa_pod) {
	_f := cast(^node_methods)((cast(^spa_interface)cast(^node)proxy).cb).funcs
	if _f != nil && _f.version >= VERSION_NODE_EVENTS && _f.set_param != nil {
		_f.set_param((cast(^spa_interface)cast(^node)proxy).cb.data, u32(param_id), flags, pod)
	} else {
		panic("could not set param")
	}
}
