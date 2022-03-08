package test_core_varint

import "core:encoding/varint"
import "core:testing"
import "core:fmt"
import "core:os"

TEST_count := 0
TEST_fail  := 0

when ODIN_TEST {
	expect  :: testing.expect
	log     :: testing.log
} else {
	expect  :: proc(t: ^testing.T, condition: bool, message: string, loc := #caller_location) {
		TEST_count += 1
		if !condition {
			TEST_fail += 1
			fmt.printf("[%v] %v\n", loc, message)
			return
		}
	}
	log     :: proc(t: ^testing.T, v: any, loc := #caller_location) {
		fmt.printf("[%v] ", loc)
		fmt.printf("log: %v\n", v)
	}
}

main :: proc() {
	t := testing.T{}

	test_dwarf(&t)

	fmt.printf("%v/%v tests successful.\n", TEST_count - TEST_fail, TEST_count)
	if TEST_fail > 0 {
		os.exit(1)
	}
}

@(test)
test_dwarf :: proc(t: ^testing.T) {
	for vector in ULEB_Vectors {
		val, size := varint.decode_uleb128(vector.encoded)

		msg := fmt.tprintf("Expected %02x to decode to %v consuming %v bytes, got %v and %v", vector.encoded, vector.value, vector.size, val, size)
		expect(t, size == vector.size && val == vector.value, msg)
	}

	for vector in ILEB_Vectors {
		val, size := varint.decode_ileb128(vector.encoded)

		msg := fmt.tprintf("Expected %02x to decode to %v consuming %v bytes, got %v and %v", vector.encoded, vector.value, vector.size, val, size)
		expect(t, size == vector.size && val == vector.value, msg)
	}
}

ULEB_Test_Vector :: struct {
	encoded: []u8,
	value:   u128,
	size:    int,
}

ULEB_Vectors :: []ULEB_Test_Vector{
	{ []u8{0x00},             0,      1 },
    { []u8{0x7f},             127,    1 },
	{ []u8{0xE5, 0x8E, 0x26}, 624485, 3 },
    { []u8{0x80},             0,      0 },
    { []u8{},                 0,      0 },
}

ILEB_Test_Vector :: struct {
	encoded: []u8,
	value:   i128,
	size:    int,
}

ILEB_Vectors :: []ILEB_Test_Vector{
	{ []u8{0x00},             0,       1 },
	{ []u8{0xC0, 0xBB, 0x78}, -123456, 3 },
    { []u8{},                 0,       0 },
}