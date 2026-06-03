package tb

// Odin bindings for Fathom Syzygy tablebase probing library
// Fathom is compiled into tb/libsyzygy.a

foreign import syzygy "libsyzygy.a"

TB_LOSS         :: 0
TB_BLESSED_LOSS :: 1
TB_DRAW         :: 2
TB_CURSED_WIN   :: 3
TB_WIN          :: 4

TB_RESULT_FAILED :: 0xFFFFFFFF

// Result decoding macros as procs
TB_GET_WDL :: proc(res: u32) -> u32 { return (res & 0x0000000F) >> 0 }
TB_GET_TO :: proc(res: u32) -> u32 { return (res & 0x000003F0) >> 4 }
TB_GET_FROM :: proc(res: u32) -> u32 { return (res & 0x0000FC00) >> 10 }
TB_GET_PROMOTES :: proc(res: u32) -> u32 { return (res & 0x00070000) >> 16 }
TB_GET_EP :: proc(res: u32) -> u32 { return (res & 0x00080000) >> 19 }
TB_GET_DTZ :: proc(res: u32) -> u32 { return (res & 0xFFF00000) >> 20 }

@(default_calling_convention="c")
foreign syzygy {
	TB_LARGEST: u32

	tb_init :: proc(path: cstring) -> bool ---
	tb_free :: proc() ---

	// WDL probe implementation (thread safe)
	tb_probe_wdl_impl :: proc(
		white: u64, black: u64,
		kings: u64, queens: u64, rooks: u64,
		bishops: u64, knights: u64, pawns: u64,
		ep: u32,
		turn: bool,
	) -> u32 ---

	// Root probe implementation (NOT thread safe)
	tb_probe_root_impl :: proc(
		white: u64, black: u64,
		kings: u64, queens: u64, rooks: u64,
		bishops: u64, knights: u64, pawns: u64,
		rule50: u32, ep: u32,
		turn: bool,
		results: ^u32,
	) -> u32 ---
}

// Syzygy state
DEFAULT_SYZYGY_PROBE_LIMIT :: 7
syzygy_path: string = ""
syzygy_probe_limit: int = DEFAULT_SYZYGY_PROBE_LIMIT
syzygy_enabled: bool = false

effective_probe_limit :: proc() -> int {
	loaded_limit := int(TB_LARGEST)
	if loaded_limit <= 0 {
		return 0
	}
	if syzygy_probe_limit < loaded_limit {
		return syzygy_probe_limit
	}
	return loaded_limit
}

// Initialize tablebases
init_syzygy :: proc(path: string) -> bool {
	if path == "" {
		syzygy_enabled = false
		return true
	}

	c_path := path  // Odin strings are null-terminated when passed to C
	ok := tb_init(cstring(raw_data(c_path)))
	if ok && TB_LARGEST > 0 {
		syzygy_enabled = true
		syzygy_path = path
		return true
	}
	syzygy_enabled = false
	return false
}

// Free tablebase resources
free_syzygy :: proc() {
	tb_free()
	syzygy_enabled = false
}

// Convert WDL result to engine score (centipawns)
wdl_to_score :: proc(wdl: u32) -> int {
	switch wdl {
	case TB_WIN:
		return 20000  // TB win
	case TB_CURSED_WIN:
		return 15000  // TB cursed win (50-move draw possible)
	case TB_DRAW:
		return 0
	case TB_BLESSED_LOSS:
		return -15000
	case TB_LOSS:
		return -20000
	}
	return 0
}
