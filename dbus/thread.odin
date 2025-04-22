package dbus

import "core:c"


ThreadFunctions :: struct {
	mask:                   ThreadFunctionBits,
	// mutex
	mutex_new:              MutexNewProc,
	mutex_free:             MutexFreeProc,
	mutex_lock:             MutexLockProc,
	mutex_unlock:           MutexUnlockProc,
	// condvar
	condvar_new:            CondVarNewProc,
	condvar_free:           CondVarFreeProc,
	condvar_wait:           CondVarWaitProc,
	condvar_wait_timeout:   CondVarWaitTimeoutProc,
	condvar_wake_one:       CondVarWakeOneProc,
	condvar_wake_all:       CondVarWakeAllProc,
	// recursive mutex
	recursive_mutex_new:    RecursiveMutexNewProc,
	recursive_mutex_free:   RecursiveMutexFreeProc,
	recursive_mutex_lock:   RecursiveMutexLockProc,
	recursive_mutex_unlock: RecursiveMutexUnlockProc,
	// padding
	padding_1:              rawptr,
	padding_2:              rawptr,
	padding_3:              rawptr,
	padding_4:              rawptr,
}

//odinfmt:disable
Mutex :: struct {}
CondVar :: struct {}
//odinfmt:enable

MutexNewProc :: #type proc "c" () -> ^Mutex
MutexFreeProc :: #type proc "c" (mutex: ^Mutex)
MutexLockProc :: #type proc "c" (mutex: ^Mutex) -> bool_t
MutexUnlockProc :: #type proc "c" (mutex: ^Mutex) -> bool_t
RecursiveMutexNewProc :: #type proc "c" () -> ^Mutex
RecursiveMutexFreeProc :: #type proc "c" (mutex: ^Mutex)
RecursiveMutexLockProc :: #type proc "c" (mutex: ^Mutex)
RecursiveMutexUnlockProc :: #type proc "c" (mutex: ^Mutex)
CondVarNewProc :: #type proc "c" () -> ^CondVar
CondVarFreeProc :: #type proc "c" (cond: ^CondVar)
CondVarWaitProc :: #type proc "c" (cond: ^CondVar, mutex: ^Mutex)
CondVarWaitTimeoutProc :: #type proc "c" (
	cond: ^CondVar,
	mutex: ^Mutex,
	timeout_ms: c.int,
) -> bool_t
CondVarWakeOneProc :: #type proc "c" (cond: ^CondVar)
CondVarWakeAllProc :: #type proc "c" (cond: ^CondVar)

ThreadFunctionBit :: enum c.uint {
	MUTEX_NEW_MASK              = 0,
	MUTEX_FREE_MASK             = 1,
	MUTEX_LOCK_MASK             = 2,
	MUTEX_UNLOCK_MASK           = 3,
	CONDVAR_NEW_MASK            = 4,
	CONDVAR_FREE_MASK           = 5,
	CONDVAR_WAIT_MASK           = 6,
	CONDVAR_WAIT_TIMEOUT_MASK   = 7,
	CONDVAR_WAKE_ONE_MASK       = 8,
	CONDVAR_WAKE_ALL_MASK       = 9,
	RECURSIVE_MUTEX_NEW_MASK    = 10,
	RECURSIVE_MUTEX_FREE_MASK   = 11,
	RECURSIVE_MUTEX_LOCK_MASK   = 12,
	RECURSIVE_MUTEX_UNLOCK_MASK = 13,
}

ThreadFunctionBits :: bit_set[ThreadFunctionBit;c.uint]
THREAD_FUNCTIONS_ALL :: ThreadFunctionBits {
	.MUTEX_NEW_MASK,
	.MUTEX_FREE_MASK,
	.MUTEX_LOCK_MASK,
	.MUTEX_UNLOCK_MASK,
	.CONDVAR_NEW_MASK,
	.CONDVAR_FREE_MASK,
	.CONDVAR_WAIT_MASK,
	.CONDVAR_WAIT_TIMEOUT_MASK,
	.CONDVAR_WAKE_ONE_MASK,
	.CONDVAR_WAKE_ALL_MASK,
	.RECURSIVE_MUTEX_NEW_MASK,
	.RECURSIVE_MUTEX_FREE_MASK,
	.RECURSIVE_MUTEX_LOCK_MASK,
	.RECURSIVE_MUTEX_UNLOCK_MASK,
}

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	threads_init :: proc(functions: ^ThreadFunctions) -> bool_t ---
	threads_default :: proc() -> bool_t ---
}
