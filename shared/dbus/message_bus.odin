package dbus

import "core:c"

BusType :: enum c.int {
	SESSION = 0,
	SYSTEM  = 1,
	STARTER = 2,
}

RequestNameFlag :: enum c.uint {
	ALLOW_REPLACEMENT = 0x1, /**< Allow another service to become the primary owner if requested */
	REPLACE_EXISTING  = 0x2, /**< Request to replace the current primary owner */
	DO_NOT_QUEUE      = 0x4, /**< If we can not become the primary owner do not place us in the queue */
}
RequestNameFlags :: bit_set[RequestNameFlag;c.uint]

RequestNameResult :: enum c.int {
	ERROR               = -1,
	REPLY_PRIMARY_OWNER = 1, /**< Service has become the primary owner of the requested name */
	REPLY_IN_QUEUE      = 2, /**< Service could not become the primary owner and has been placed in the queue */
	REPLY_EXISTS        = 3, /**< Service is already in the queue */
	REPLY_ALREADY_OWNER = 4, /**< Service is already the primary owner */
}

ReleaseNameResult :: enum c.int {
	ERROR              = -1,
	REPLY_RELEASED     = 1, /**< Service was released from the given name */
	REPLY_NON_EXISTENT = 2, /**< The given name does not exist on the bus */
	REPLY_NOT_OWNER    = 3, /**< Service is not an owner of the given name */
}

GetServiceByNameResult :: enum c.uint32_t {
	DONT_CARE             = 0,
	REPLY_SUCCESS         = 1, /**< Service was auto started */
	REPLY_ALREADY_RUNNING = 2, /**< Service was already running */
}

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	bus_get :: proc(type: BusType, error: ^Error) -> ^Connection ---
	bus_get_private :: proc(type: BusType, error: ^Error) -> ^Connection ---
	bus_register :: proc(connection: ^Connection, error: ^Error) -> bool_t ---
	bus_set_unique_name :: proc(connection: ^Connection, unique_name: cstring) -> bool_t ---
	bus_get_unique_name :: proc(connection: ^Connection) -> cstring ---
	bus_get_unix_user :: proc(connection: ^Connection, name: cstring, error: ^Error) -> c.ulong ---
	bus_get_id :: proc(connection: ^Connection, error: ^Error) -> cstring ---
	bus_request_name :: proc(connection: ^Connection, name: cstring, flags: RequestNameFlags, error: ^Error) -> RequestNameResult ---
	bus_release_name :: proc(connection: ^Connection, name: cstring, error: ^Error) -> ReleaseNameResult ---
	bus_name_has_owner :: proc(connection: ^Connection, name: cstring, error: ^Error) -> bool_t ---
	bus_start_service_by_name :: proc(connection: ^Connection, name: cstring, flags: c.uint32_t, result: ^GetServiceByNameResult, error: Error) -> bool_t ---
  bus_add_match :: proc(connection: ^Connection, rule: cstring, error: ^Error) ---
  bus_remove_match :: proc(connection: ^Connection, rule: cstring, error: ^Error) ---
}
