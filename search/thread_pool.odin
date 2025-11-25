package search

import "../board"
import "../moves"
import "core:sync"
import "core:thread"

// Thread Pool for parallel search
Thread_Pool :: struct {
	threads:      [dynamic]^thread.Thread,
	thread_count: int,
}

global_thread_pool: ^Thread_Pool

// Initialize thread pool
init_thread_pool :: proc(count: int) {
	if global_thread_pool != nil {
		destroy_thread_pool()
	}

	pool := new(Thread_Pool)
	pool.thread_count = count
	pool.threads = make([dynamic]^thread.Thread, 0, count)

	global_thread_pool = pool
}

// Destroy thread pool
destroy_thread_pool :: proc() {
	if global_thread_pool == nil {return}

	// Clean up any active threads
	for t in global_thread_pool.threads {
		if t != nil {
			thread.join(t)
			thread.destroy(t)
		}
	}

	delete(global_thread_pool.threads)
	free(global_thread_pool)
	global_thread_pool = nil
}

// Thread worker data
Thread_Worker_Data :: struct {
	thread_id: int,
	board:     board.Board,
	depth:     int,
	multi_pv:  int,
}

// Worker thread procedure
search_worker :: proc(t: ^thread.Thread) {
	data := cast(^Thread_Worker_Data)t.data

	// Add search diversity: each thread searches at slightly different depth
	// This reduces duplicate work across threads
	adjusted_depth := data.depth
	if data.thread_id % 2 == 1 {
		adjusted_depth = max(1, data.depth - 1) // Odd threads search 1 ply shallower
	}

	// Search the position (suppress bestmove output for workers)
	// Each thread has its own killer/history tables (thread-local globals in Odin)
	search_position(&data.board, adjusted_depth, data.multi_pv, output_bestmove = false)

	// Clean up worker data
	free(data)
}

// Parallel search - spawns helper threads
parallel_search :: proc(b: ^board.Board, depth: int, multi_pv: int) {
	if global_thread_pool == nil || global_thread_pool.thread_count <= 1 {
		// Fall back to single-threaded search
		search_position(b, depth, multi_pv)
		return
	}

	// Clear previous threads
	for t in global_thread_pool.threads {
		if t != nil {
			thread.join(t)
			thread.destroy(t)
			free(t.data)
		}
	}
	clear(&global_thread_pool.threads)

	// Spawn helper threads (main thread will also search)
	// Threads 1..N-1 are helpers, thread 0 is main
	for i in 1 ..< global_thread_pool.thread_count {
		worker_data := new(Thread_Worker_Data)
		worker_data.thread_id = i
		worker_data.board = b^
		worker_data.depth = depth
		worker_data.multi_pv = 1 // Helpers use single PV

		t := thread.create(search_worker)
		t.data = worker_data
		thread.start(t)
		append(&global_thread_pool.threads, t)
	}

	// Main thread (thread 0) also searches
	search_position(b, depth, multi_pv)

	// Wait for all helper threads to complete
	for t in global_thread_pool.threads {
		thread.join(t)
		thread.destroy(t)
		// Note: data already freed by worker
	}
	clear(&global_thread_pool.threads)
}
