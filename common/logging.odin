package common

import "base:runtime"

LOG_LEVEL_DEFAULT :: "debug" when ODIN_DEBUG else "info"
LOG_LEVEL :: #config(LOG_LEVEL, LOG_LEVEL_DEFAULT)

get_log_level :: #force_inline proc() -> runtime.Logger_Level {
	when LOG_LEVEL == "debug" {
		return .Debug
	} else when LOG_LEVEL == "info" {
		return .Info
	} else when LOG_LEVEL == "warning" {
		return .Warning
	} else when LOG_LEVEL == "error" {
		return .Error
	} else when LOG_LEVEL == "fatal" {
		return .Fatal
	} else {
		#panic(
			"Unknown `ODIN_TEST_LOG_LEVEL`: \"" +
			LOG_LEVEL +
			"\", possible levels are: \"debug\", \"info\", \"warning\", \"error\", or \"fatal\".",
		)
	}
}
