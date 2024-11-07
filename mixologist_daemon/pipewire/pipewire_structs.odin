package pipewire

import "core:c"
import "core:sys/posix"

properties :: struct {
	dict:  spa_dict,
	flags: u32,
}

main_loop :: struct {
	loop:          ^loop,
	listener_list: spa_hook_list,
	// status:        bit_field u8 {
	// 	created: uint | 1,
	// 	running: uint | 1,
	// },
}

thread_loop :: struct {
	loop:                 ^loop,
	name:                 [16]u8,
	listener_list:        spa_hook_list,
	lock:                 posix.pthread_mutex_t,
	cond:                 posix.pthread_cond_t,
	accept_cond:          posix.pthread_cond_t,
	thread:               posix.pthread_t,
	recurse:              c.int,
	hook:                 spa_hook,
	event:                rawptr, // ^spa_source;
	n_waiting:            c.int,
	n_waiting_for_accept: c.int,
	status:               bit_field u8 {
		created:      c.uint | 1,
		running:      c.uint | 1,
		start_signal: c.uint | 1,
	},
}

thread_loop_events :: struct {} // [TODO] fill out fields

loop :: struct {
	system:  rawptr,
	loop:    rawptr,
	control: rawptr,
	utils:   rawptr,
	name:    cstring,
}

settings :: struct {
	log_level:              u32,
	clock_rate:             u32,
	clock_rates:            [32]u32,
	n_clock_rates:          u32,
	clock_quantum:          u32,
	clock_min_quantum:      u32,
	clock_max_quantum:      u32,
	clock_quantum_limit:    u32,
	clock_quantum_floor:    u32,
	video_size:             [2]u32,
	video_rate:             [2]u32,
	link_max_buffers:       u32,
	status:                 bit_field u8 {
		mem_warn_mlock:             c.uint | 1,
		mem_allow_mlock:            c.uint | 1,
		clock_power_of_two_quantum: c.uint | 1,
		check_quantum:              c.uint | 1,
		check_rate:                 c.uint | 1,
	},
	clock_rate_update_mode: c.int,
	clock_force_rate:       u32,
	clock_force_quantum:    u32,
}

pw_map :: struct {
	items:     array,
	free_list: u32,
}

array :: struct {
	data:   rawptr,
	size:   uint,
	alloc:  uint,
	extend: uint,
}


pw_context :: struct {
	core:                   rawptr,
	conf:                   ^properties,
	properties:             ^properties,
	defaults:               settings,
	settings:               settings,
	settings_impl:          rawptr,
	pool:                   rawptr,
	stamp:                  u64,
	serial:                 u64,
	generation:             u64,
	globals:                pw_map,
	core_impl_list:         spa_list,
	protocol_list:          spa_list,
	core_list:              spa_list,
	registry_resource_list: spa_list,
	module_list:            spa_list,
	device_list:            spa_list,
	global_list:            spa_list,
	client_list:            spa_list,
	node_list:              spa_list,
	factory_list:           spa_list,
	metadata_list:          spa_list,
	link_list:              spa_list,
	control_list:           [2]spa_list,
	export_list:            spa_list,
	driver_list:            spa_list,
	driver_listener_list:   spa_hook_list,
	listener_list:          spa_hook_list,
	thread_utils:           rawptr,
	main_loop:              ^loop,
	work_queue:             rawptr,
	support:                [16]spa_support,
	n_support:              u32,
	factory_lib:            array,
	objects:                array,
	current_client:         rawptr,
	sc_pagesize:            c.long,
	freewheeling:           bit_field u8 {
		freewheeling: c.int | 1,
	},
	user_data:              rawptr,
}

impl_metadata :: struct {
	version:      u32,
	add_listener: proc(
		object: rawptr,
		listener: ^spa_hook,
		events: ^metadata_events,
		data: rawptr,
	) -> c.int,
	set_property: proc(object: rawptr, subject: u32, key, type, value: cstring) -> c.int,
	clear:        proc(object: rawptr) -> c.int,
}

metadata_events :: struct {
	version:  u32,
	property: proc(data: rawptr, subject: u32, key, type, value: cstring) -> c.int,
}

impl_module :: struct {
	ctx:             ^pw_context,
	link:            spa_list,
	global:          rawptr,
	global_listener: spa_hook,
	properties:      ^properties,
	info:            module_info,
	listener_list:   spa_hook_list,
	user_data:       rawptr,
}

impl_module_events :: struct {
	version:     u32,
	destroy:     proc "c" (data: rawptr),
	free:        proc "c" (data: rawptr),
	initialized: proc "c" (data: rawptr),
	registered:  proc "c" (data: rawptr),
}

module_info :: struct {
	id:          u32,
	name:        cstring,
	filename:    cstring,
	args:        cstring,
	change_mask: u64,
	props:       spa_dict,
}

stream :: struct {
	core:             rawptr, // struct core*
	core_listener:    spa_hook,
	link:             spa_list,
	name:             cstring,
	properties:       ^properties,
	node_id:          u32,
	state:            stream_state,
	error:            cstring,
	error_res:        c.int,
	listener_list:    spa_hook_list,
	proxy:            rawptr, // struct proxy*
	proxy_listener:   spa_hook,
	node:             rawptr, // struct impl_node*
	node_listener:    spa_hook,
	node_rt_listener: spa_hook,
	controls:         spa_list,
}

stream_state :: enum c.int {
	PW_STREAM_STATE_ERROR       = -1,
	PW_STREAM_STATE_UNCONNECTED = 0,
	PW_STREAM_STATE_CONNECTING  = 1,
	PW_STREAM_STATE_PAUSED      = 2,
	PW_STREAM_STATE_STREAMING   = 3,
}

VERSION_REGISTRY_EVENTS :: 0
registry_events :: struct {
	version:       u32,
	/**
	 * Notify of a new global object
	 *
	 * The registry emits this event when a new global object is
	 * available.
	 *
	 * \param id the global object id
	 * \param permissions the permissions of the object
	 * \param type the type of the interface
	 * \param version the version of the interface
	 * \param props extra properties of the global
	 */
	global_add:    proc "c" (
		data: rawptr,
		id: u32,
		permissions: u32,
		type: cstring,
		version: u32,
		props: ^spa_dict,
	),
	/**
	 * Notify of a global object removal
	 *
	 * Emitted when a global object was removed from the registry.
	 * If the client has any bindings to the global, it should destroy
	 * those.
	 *
	 * \param id the id of the global that was removed
	 */
	global_remove: proc "c" (data: rawptr, id: u32),
}

registry_methods :: struct {
	version:      u32,
	add_listener: proc "c" (
		object: rawptr,
		listener: ^spa_hook,
		events: ^registry_events,
		data: rawptr,
	) -> c.int,
	/**
	 * Bind to a global object
	 *
	 * Bind to the global object with \a id and use the client proxy
	 * with new_id as the proxy. After this call, methods can be
	 * send to the remote global object and events can be received
	 *
	 * \param id the global id to bind to
	 * \param type the interface type to bind to
	 * \param version the interface version to use
	 * \returns the new object
	 */
	bind:         proc "c" (
		object: rawptr,
		id: u32,
		type: cstring,
		version: u32,
		use_data_size: c.size_t,
	) -> rawptr,
	/**
	 * Attempt to destroy a global object
	 *
	 * Try to destroy the global object.
	 *
	 * \param id the global id to destroy. The client needs X permissions
	 * on the global.
	 */
	destroy:      proc "c" (object: rawptr, id: u32) -> c.int,
}

proxy :: struct {
	impl:                 spa_interface,
	core:                 ^core,
	id:                   u32,
	type:                 cstring,
	version:              u32,
	bound_id:             u32,
	refcount:             c.int,
	status:               bit_field u8 {
		zombie:    c.uint | 1,
		removed:   c.uint | 1,
		destroyed: c.uint | 1,
		in_map:    c.uint | 1,
	},
	listener_list:        spa_hook_list,
	object_listener_list: spa_hook_list,
	marshal:              rawptr, // const struct protocol_marshal *marshal
	user_data:            rawptr,
}

proxy_events :: struct {
	version:     u32,
	destroy:     proc(data: rawptr),
	/** a proxy is bound to a global id */
	bound:       proc(data: rawptr, global_id: u32),
	/** a proxy is removed from the server. Use proxy_destroy to
	 * free the proxy. */
	removed:     proc(data: rawptr),
	/** a reply to a sync method completed */
	done:        proc(data: rawptr, seq: c.int),
	/** an error occurred on the proxy */
	error:       proc(data: rawptr, seq: c.int, res: c.int, message: cstring),
	bound_props: proc(data: rawptr, global_id: u32, props: ^spa_dict),
}

core :: struct {
	proxy:               proxy,
	ctx:                 ^pw_context,
	link:                spa_list,
	properties:          ^properties,
	pool:                rawptr, // struct mempool*
	core_listener:       spa_hook,
	proxy_core_listener: spa_hook,
	objects:             pw_map,
	client:              ^client,
	stream_list:         spa_list,
	filter_list:         spa_list,
	conn:                rawptr, // struct protocol_client *
	recv_seq:            c.int,
	send_seq:            c.int,
	recv_generation:     u64,
	status:              bit_field u8 {
		removed:   c.uint | 1,
		destroyed: c.uint | 1,
	},
	user_data:           rawptr,
}

core_events :: struct {
	version:     u32,
	/**
	 * Notify new core info
	 *
	 * This event is emitted when first bound to the core or when the
	 * hello method is called.
	 *
	 * \param info new core info
	 */
	info:        proc "c" (data: rawptr, info: ^core_info),
	/**
	 * Emit a done event
	 *
	 * The done event is emitted as a result of a sync method with the
	 * same seq number.
	 *
	 * \param seq the seq number passed to the sync method call
	 */
	done:        proc "c" (data: rawptr, id: u32, seq: c.int),
	/** Emit a ping event
	 *
	 * The client should reply with a pong reply with the same seq
	 * number.
	 */
	ping:        proc "c" (data: rawptr, id: u32, seq: c.int),
	/**
	 * Fatal error event
         *
         * The error event is sent out when a fatal (non-recoverable)
         * error has occurred. The id argument is the proxy object where
         * the error occurred, most often in response to a request to that
         * object. The message is a brief description of the error,
         * for (debugging) convenience.
	 *
	 * This event is usually also emitted on the proxy object with
	 * \a id.
	 *
         * \param id object where the error occurred
         * \param seq the sequence number that generated the error
         * \param res error code
         * \param message error description
	 */
	error:       proc "c" (data: rawptr, id: u32, seq: c.int, res: c.int, message: cstring),
	/**
	 * Remove an object ID
         *
         * This event is used internally by the object ID management
         * logic. When a client deletes an object, the server will send
         * this event to acknowledge that it has seen the delete request.
         * When the client receives this event, it will know that it can
         * safely reuse the object ID.
	 *
         * \param id deleted object ID
	 */
	remove_id:   proc "c" (data: rawptr, id: u32),
	/**
	 * Notify an object binding
	 *
	 * This event is emitted when a local object ID is bound to a
	 * global ID. It is emitted before the global becomes visible in the
	 * registry.
	 *
	 * The bound_props event is an enhanced version of this event that
	 * also contains the extra global properties.
	 *
	 * \param id bound object ID
	 * \param global_id the global id bound to
	 */
	bound_id:    proc "c" (data: rawptr, id: u32, global_id: u32),
	/**
	 * Add memory for a client
	 *
	 * Memory is given to a client as \a fd of a certain
	 * memory \a type.
	 *
	 * Further references to this fd will be made with the per memory
	 * unique identifier \a id.
	 *
	 * \param id the unique id of the memory
	 * \param type the memory type, one of enum spa_data_type
	 * \param fd the file descriptor
	 * \param flags extra flags
	 */
	add_mem:     proc "c" (data: rawptr, id: u32, type: u32, fd: c.int, flags: u32),
	/**
	 * Remove memory for a client
	 *
	 * \param id the memory id to remove
	 */
	remove_mem:  proc "c" (data: rawptr, id: u32),
	/**
	 * Notify an object binding
	 *
	 * This event is emitted when a local object ID is bound to a
	 * global ID. It is emitted before the global becomes visible in the
	 * registry.
	 *
	 * This is an enhanced version of the bound_id event.
	 *
	 * \param id bound object ID
	 * \param global_id the global id bound to
	 * \param props The properties of the new global object.
	 *
	 * Since version 4:1
	 */
	bound_props: proc "c" (data: rawptr, id: u32, global_id: u32, props: ^spa_dict),
}

core_methods :: struct {
	version:       u32,
	add_listener:  proc "c" (
		object: rawptr,
		listener: ^spa_hook,
		events: ^core_events,
		data: rawptr,
	) -> c.int,
	/**
	 * Start a conversation with the server. This will send
	 * the core info and will destroy all resources for the client
	 * (except the core and client resource).
	 *
	 * This requires X permissions on the core.
	 */
	hello:         proc "c" (object: rawptr, version: u32) -> c.int,
	/**
	 * Do server roundtrip
	 *
	 * Ask the server to emit the 'done' event with \a seq.
	 *
	 * Since methods are handled in-order and events are delivered
	 * in-order, this can be used as a barrier to ensure all previous
	 * methods and the resulting events have been handled.
	 *
	 * \param seq the seq number passed to the done event
	 *
	 * This requires X permissions on the core.
	 */
	sync:          proc "c" (object: rawptr, id: u32, seq: c.int) -> c.int,
	/**
	 * Reply to a server ping event.
	 *
	 * Reply to the server ping event with the same seq.
	 *
	 * \param seq the seq number received in the ping event
	 *
	 * This requires X permissions on the core.
	 */
	pong:          proc "c" (object: rawptr, id: u32, seq: c.int) -> c.int,
	/**
	 * Fatal error event
         *
         * The error method is sent out when a fatal (non-recoverable)
         * error has occurred. The id argument is the proxy object where
         * the error occurred, most often in response to an event on that
         * object. The message is a brief description of the error,
         * for (debugging) convenience.
	 *
	 * This method is usually also emitted on the resource object with
	 * \a id.
	 *
         * \param id resource id where the error occurred
         * \param res error code
         * \param message error description
	 *
	 * This requires X permissions on the core.
	 */
	error:         proc "c" (
		object: rawptr,
		id: u32,
		seq: c.int,
		res: c.int,
		message: cstring,
	) -> c.int,
	/**
	 * Get the registry object
	 *
	 * Create a registry object that allows the client to list and bind
	 * the global objects available from the PipeWire server
	 * \param version the client version
	 * \param user_data_size extra size
	 *
	 * This requires X permissions on the core.
	 */
	get_registry:  proc "c" (object: rawptr, version: u32, user_data_size: c.uint) -> ^registry,

	/**
	 * Create a new object on the PipeWire server from a factory.
	 *
	 * \param factory_name the factory name to use
	 * \param type the interface to bind to
	 * \param version the version of the interface
	 * \param props extra properties
	 * \param user_data_size extra size
	 *
	 * This requires X permissions on the core.
	 */
	create_object: proc "c" (
		object: rawptr,
		factory_name: cstring,
		type: cstring,
		version: u32,
		props: ^spa_dict,
		user_data_size: c.uint,
	) -> rawptr,
	/**
	 * Destroy an resource
	 *
	 * Destroy the server resource for the given proxy.
	 *
	 * \param obj the proxy to destroy
	 *
	 * This requires X permissions on the core.
	 */
	destroy:       proc "c" (object: rawptr, proxy: rawptr) -> c.int,
}

node_events :: struct {
	version: u32,
	/**
	 * Notify node info
	 *
	 * \param info info about the node
	 */
	info:    proc(data: rawptr, info: ^node_info),
	/**
	 * Notify a node param
	 *
	 * Event emitted as a result of the enum_params method.
	 *
	 * \param seq the sequence number of the request
	 * \param id the param id
	 * \param index the param index
	 * \param next the param index of the next param
	 * \param param the parameter
	 */
	param:   proc(data: rawptr, seq: c.int, id: u32, idx: u32, next: u32, param: ^spa_pod),
}

node_state :: enum c.int {
	PW_NODE_STATE_ERROR     = -1, /**< error state */
	PW_NODE_STATE_CREATING  = 0, /**< the node is being created */
	PW_NODE_STATE_SUSPENDED = 1, /**< the node is suspended, the device might
					 *   be closed */
	PW_NODE_STATE_IDLE      = 2, /**< the node is running but there is no active
					 *   port */
	PW_NODE_STATE_RUNNING   = 3, /**< the node is running */
}

spa_param_info :: struct {
	id:      u32,
	flags:   u32,
	user:    u32,
	seq:     i32,
	padding: [4]u32,
}

node_info :: struct {
	id:               u32,
	max_input_ports:  u32,
	max_output_ports: u32,
	change_mask:      u64,
	n_input_ports:    u32,
	n_output_ports:   u32,
	state:            node_state,
	error:            cstring,
	props:            ^spa_dict,
	params:           ^spa_param_info,
	n_params:         u32,
}

node_methods :: struct {
	version:          u32,
	add_listener:     proc(
		object: rawptr,
		listener: ^spa_hook,
		events: ^node_events,
		data: rawptr,
	) -> c.int,
	/**
	 * Subscribe to parameter changes
	 *
	 * Automatically emit param events for the given ids when
	 * they are changed.
	 *
	 * \param ids an array of param ids
	 * \param n_ids the number of ids in \a ids
	 *
	 * This requires X permissions on the node.
	 */
	subscribe_params: proc(object: rawptr, ids: ^u32, n_ids: u32) -> c.int,
	/**
	 * Enumerate node parameters
	 *
	 * Start enumeration of node parameters. For each param, a
	 * param event will be emitted.
	 *
	 * \param seq a sequence number to place in the reply
	 * \param id the parameter id to enum or PW_ID_ANY for all
	 * \param start the start index or 0 for the first param
	 * \param num the maximum number of params to retrieve
	 * \param filter a param filter or NULL
	 *
	 * This requires X permissions on the node.
	 */
	enum_params:      proc(
		object: rawptr,
		seq: c.int,
		id: u32,
		start: u32,
		num: u32,
		filter: ^spa_pod,
	) -> c.int,
	/**
	 * Set a parameter on the node
	 *
	 * \param id the parameter id to set
	 * \param flags extra parameter flags
	 * \param param the parameter to set
	 *
	 * This requires X and W permissions on the node.
	 */
	set_param:        proc(object: rawptr, id: u32, flags: u32, param: ^spa_pod) -> c.int,
	/**
	 * Send a command to the node
	 *
	 * \param command the command to send
	 *
	 * This requires X and W permissions on the node.
	 */
	send_command:     proc(object: rawptr, command: ^spa_command) -> c.int,
}

core_info :: struct {
	id:          u32,
	cookie:      u32,
	user_name:   cstring,
	host_name:   cstring,
	version:     cstring,
	name:        cstring,
	change_mask: u64,
	props:       ^spa_dict,
}

global :: struct {
	ctx:             ^pw_context,
	link:            spa_list,
	id:              u32,
	properties:      ^properties,
	listener_list:   spa_hook_list,
	type:            cstring,
	version:         u32,
	permission_mask: u32,
	// global_bind_func_t func;	/**< bind function */
	func:            rawptr,
	object:          rawptr,
	serial:          u64,
	generation:      u64,
	resource_list:   spa_list,
	// unsigned int registered:1;
	// unsigned int destroyed:1;
}

link_events :: struct {
	version: u32,
	/**
	 * Notify link info
	 *
	 * \param info info about the link
	 */
	info:    proc(data: rawptr, info: ^link_info),
}

link_info :: struct {
	id:             u32, /**< id of the global */
	output_node_id: u32, /**< server side output node id */
	output_port_id: u32, /**< output port id */
	input_node_id:  u32, /**< server side input node id */
	input_port_id:  u32, /**< input port id */
	change_mask:    u64, /**< bitfield of changed fields since last call */
	state:          link_state, /**< the current state of the link */
	error:          cstring, /**< an error reason if \a state is error */
	format:         spa_pod, /**< format over link */
	props:          ^spa_dict, /**< the properties of the link */
}

link_state :: enum c.int {
	PW_LINK_STATE_ERROR       = -2, /**< the link is in error */
	PW_LINK_STATE_UNLINKED    = -1, /**< the link is unlinked */
	PW_LINK_STATE_INIT        = 0, /**< the link is initialized */
	PW_LINK_STATE_NEGOTIATING = 1, /**< the link is negotiating formats */
	PW_LINK_STATE_ALLOCATING  = 2, /**< the link is allocating buffers */
	PW_LINK_STATE_PAUSED      = 3, /**< the link is paused */
	PW_LINK_STATE_ACTIVE      = 4, /**< the link is active */
}

registry :: struct {}
client :: struct {}
node :: struct {}
