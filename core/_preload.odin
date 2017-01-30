#shared_global_scope;

#import "os.odin";
#import "fmt.odin";
#import "mem.odin";
#import "utf8.odin";

// IMPORTANT NOTE(bill): `type_info` & `type_info_val` cannot be used within a
// #shared_global_scope due to  the internals of the compiler.
// This could change at a later date if the all these data structures are
// implemented within the compiler rather than in this "preload" file


// IMPORTANT NOTE(bill): Do not change the order of any of this data
// The compiler relies upon this _exact_ order
Type_Info_Member :: struct #ordered {
	name:      string,     // can be empty if tuple
	type_info: ^Type_Info,
	offset:    int,        // offsets are not used in tuples
}
Type_Info_Record :: struct #ordered {
	fields:  []Type_Info_Member,
	size:    int, // in bytes
	align:   int, // in bytes
	packed:  bool,
	ordered: bool,
}
Type_Info_Enum_Value :: raw_union {
	f: f64,
	i: i64,
}

// NOTE(bill): This much the same as the compiler's
Calling_Convention :: enum {
	ODIN = 0,
	C    = 1,
	STD  = 2,
	FAST = 3,
}

Type_Info :: union {
	Named: struct #ordered {
		name: string,
		base: ^Type_Info, // This will _not_ be a Type_Info.Named
	},
	Integer: struct #ordered {
		size:   int, // in bytes
		signed: bool,
	},
	Float: struct #ordered {
		size: int, // in bytes
	},
	Any:     struct #ordered {},
	String:  struct #ordered {},
	Boolean: struct #ordered {},
	Pointer: struct #ordered {
		elem: ^Type_Info, // nil -> rawptr
	},
	Maybe: struct #ordered {
		elem: ^Type_Info,
	},
	Procedure: struct #ordered {
		params:     ^Type_Info, // Type_Info.Tuple
		results:    ^Type_Info, // Type_Info.Tuple
		variadic:   bool,
		convention: Calling_Convention,
	},
	Array: struct #ordered {
		elem:      ^Type_Info,
		elem_size: int,
		count:     int,
	},
	Dynamic_Array: struct #ordered {
		elem:      ^Type_Info,
		elem_size: int,
	},
	Slice: struct #ordered {
		elem:      ^Type_Info,
		elem_size: int,
	},
	Vector: struct #ordered {
		elem:      ^Type_Info,
		elem_size: int,
		count:     int,
		align:     int,
	},
	Tuple:     Type_Info_Record,
	Struct:    Type_Info_Record,
	Union:     Type_Info_Record,
	Raw_Union: Type_Info_Record,
	Enum: struct #ordered {
		base:  ^Type_Info,
		names: []string,
		values: []Type_Info_Enum_Value,
	},
}

// // NOTE(bill): only the ones that are needed (not all types)
// // This will be set by the compiler
// immutable __type_infos: []Type_Info;

type_info_base :: proc(info: ^Type_Info) -> ^Type_Info {
	if info == nil {
		return nil;
	}
	base := info;
	match type i in base {
	case Type_Info.Named:
		base = i.base;
	}
	return base;
}



assume :: proc(cond: bool) #foreign __llvm_core "llvm.assume";

__debug_trap       :: proc()        #foreign __llvm_core "llvm.debugtrap";
__trap             :: proc()        #foreign __llvm_core "llvm.trap";
read_cycle_counter :: proc() -> u64 #foreign __llvm_core "llvm.readcyclecounter";


// IMPORTANT NOTE(bill): Must be in this order (as the compiler relies upon it)
Allocator_Mode :: enum u8 {
	ALLOC,
	FREE,
	FREE_ALL,
	RESIZE,
}
Allocator_Proc :: type proc(allocator_data: rawptr, mode: Allocator_Mode,
                            size, alignment: int,
                            old_memory: rawptr, old_size: int, flags: u64) -> rawptr;
Allocator :: struct #ordered {
	procedure: Allocator_Proc,
	data:      rawptr,
}

Context :: struct #ordered {
	thread_id: int,

	allocator: Allocator,

	user_data:  rawptr,
	user_index: int,
}

thread_local __context: Context;


DEFAULT_ALIGNMENT :: align_of([vector 4]f32);


__check_context :: proc() {
	c := ^__context;

	if c.allocator.procedure == nil {
		c.allocator = default_allocator();
	}
	if c.thread_id == 0 {
		c.thread_id = os.current_thread_id();
	}
}

alloc :: proc(size: int) -> rawptr #inline { return alloc_align(size, DEFAULT_ALIGNMENT); }

alloc_align :: proc(size, alignment: int) -> rawptr #inline {
	__check_context();
	a := context.allocator;
	return a.procedure(a.data, Allocator_Mode.ALLOC, size, alignment, nil, 0, 0);
}

free_ptr_with_allocator :: proc(a: Allocator, ptr: rawptr) #inline {
	if ptr == nil {
		return;
	}
	a.procedure(a.data, Allocator_Mode.FREE, 0, 0, ptr, 0, 0);
}

free_ptr :: proc(ptr: rawptr) #inline {
	__check_context();
	free_ptr_with_allocator(context.allocator, ptr);
}
free_all :: proc() #inline {
	__check_context();
	a := context.allocator;
	a.procedure(a.data, Allocator_Mode.FREE_ALL, 0, 0, nil, 0, 0);
}


resize       :: proc(ptr: rawptr, old_size, new_size: int) -> rawptr #inline { return resize_align(ptr, old_size, new_size, DEFAULT_ALIGNMENT); }
resize_align :: proc(ptr: rawptr, old_size, new_size, alignment: int) -> rawptr #inline {
	__check_context();
	a := context.allocator;
	return a.procedure(a.data, Allocator_Mode.RESIZE, new_size, alignment, ptr, old_size, 0);
}



default_resize_align :: proc(old_memory: rawptr, old_size, new_size, alignment: int) -> rawptr {
	if old_memory == nil {
		return alloc_align(new_size, alignment);
	}

	if new_size == 0 {
		free(old_memory);
		return nil;
	}

	if new_size == old_size {
		return old_memory;
	}

	new_memory := alloc_align(new_size, alignment);
	if new_memory == nil {
		return nil;
	}

	mem.copy(new_memory, old_memory, min(old_size, new_size));;
	free(old_memory);
	return new_memory;
}


default_allocator_proc :: proc(allocator_data: rawptr, mode: Allocator_Mode,
                               size, alignment: int,
                               old_memory: rawptr, old_size: int, flags: u64) -> rawptr {
	using Allocator_Mode;

	match mode {
	case ALLOC:
		return os.heap_alloc(size);

	case FREE:
		os.heap_free(old_memory);
		return nil;

	case FREE_ALL:
		// NOTE(bill): Does nothing

	case RESIZE:
		ptr := os.heap_resize(old_memory, size);
		assert(ptr != nil);
		return ptr;
	}

	return nil;
}

default_allocator :: proc() -> Allocator {
	return Allocator{
		procedure = default_allocator_proc,
		data = nil,
	};
}











__string_eq :: proc(a, b: string) -> bool {
	if a.count != b.count {
		return false;
	}
	if a.data == b.data {
		return true;
	}
	return mem.compare(cast(rawptr)a.data, cast(rawptr)b.data, a.count) == 0;
}

__string_cmp :: proc(a, b: string) -> int {
	return mem.compare(cast(rawptr)a.data, cast(rawptr)b.data, min(a.count, b.count));
}

__string_ne :: proc(a, b: string) -> bool #inline { return !__string_eq(a, b); }
__string_lt :: proc(a, b: string) -> bool #inline { return __string_cmp(a, b) < 0; }
__string_gt :: proc(a, b: string) -> bool #inline { return __string_cmp(a, b) > 0; }
__string_le :: proc(a, b: string) -> bool #inline { return __string_cmp(a, b) <= 0; }
__string_ge :: proc(a, b: string) -> bool #inline { return __string_cmp(a, b) >= 0; }


__assert :: proc(file: string, line, column: int, msg: string) #inline {
	fmt.fprintf(os.stderr, "%s(%d:%d) Runtime assertion: %s\n",
	            file, line, column, msg);
	__debug_trap();
}

__bounds_check_error :: proc(file: string, line, column: int, index, count: int) {
	if 0 <= index && index < count {
		return;
	}
	fmt.fprintf(os.stderr, "%s(%d:%d) Index %d is out of bounds range 0..<%d\n",
	            file, line, column, index, count);
	__debug_trap();
}

__slice_expr_error :: proc(file: string, line, column: int, low, high: int) {
	if 0 <= low && low <= high {
		return;
	}
	fmt.fprintf(os.stderr, "%s(%d:%d) Invalid slice indices: [%d:%d]\n",
	            file, line, column, low, high);
	__debug_trap();
}
__substring_expr_error :: proc(file: string, line, column: int, low, high: int) {
	if 0 <= low && low <= high {
		return;
	}
	fmt.fprintf(os.stderr, "%s(%d:%d) Invalid substring indices: [%d:%d]\n",
	            file, line, column, low, high);
	__debug_trap();
}

__string_decode_rune :: proc(s: string) -> (rune, int) #inline {
	return utf8.decode_rune(s);
}


Raw_Dynamic_Array :: struct #ordered {
	data:      rawptr,
	count:     int,
	capacity:  int,
	allocator: Allocator,
};

__dynamic_array_reserve :: proc(array_: rawptr, elem_size, elem_align: int, capacity: int) -> bool {
	array := cast(^Raw_Dynamic_Array)array_;

	if capacity <= array.capacity {
		return true;
	}

	__check_context();
	if array.allocator.procedure == nil {
		array.allocator = context.allocator;
	}
	assert(array.allocator.procedure != nil);

	old_size  := array.capacity * elem_size;
	new_size  := capacity * elem_size;
	allocator := array.allocator;

	new_data := allocator.procedure(allocator.data, Allocator_Mode.RESIZE, new_size, elem_align, array.data, old_size, 0);
	if new_data == nil {
		return false;
	}

	array.data = new_data;
	array.capacity = capacity;
	return true;
}


__dynamic_array_append :: proc(array_: rawptr, elem_size, elem_align: int,
                               items: rawptr, item_count: int) -> int {
	array := cast(^Raw_Dynamic_Array)array_;

	ok := true;
	if array.capacity <= array.count+item_count {
		capacity := 2 * array.capacity + max(8, item_count);
		ok = __dynamic_array_reserve(array, elem_size, elem_align, capacity);
	}
	if !ok {
		// TODO(bill): Better error handling for failed reservation
		return array.count;
	}
	data := cast(^byte)array.data;
	assert(data != nil);
	mem.copy(data + (elem_size*array.count), items, elem_size * item_count);
	array.count += item_count;
	return array.count;
}
