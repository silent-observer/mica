# Netlist Format Specification

Netlist is the intermediate representation used by various toolchain stages.
While its primary purpose is carrying information from stage to stage,
it is intentionally designed to be debuggable *and writable* by a human.

Key features:
- **human-readable** - a human should be able to read the format and understand it easily;
- **human-writable** - a human can write a whole netlist by hand, no weird numeric IDs;
- **monotonic** - every stage after technology mapping *only adds* new info to the file,
  never removing or rewriting anything. This makes easy to follow diffs;
- **appendable** - the changes can literally be appended at the end of the file, no edits needed;
- **consistent** with textual bitstream format - uses the same kind of lexical structure;
- **flat** - does not have notion of modules, so represents a physical configuration;
- **scalar** - only scalar nets, buses are simply fancy syntax sugar;
- **single source of truth** - no duplicate information, avoids drift when manually editing, for example, nets do not duplicate their fanout in the net declaration;
- **extensible** - metadata named with `@` passes through unaffected;
- **partial designs parse** - even if something is missing, the parser shouldn't complain - the tools should.

Full netlist grammar is written in netlist-grammar.txt.

## Header

The file header is something like
```
format 1;
device "M1/S";
design "toggle";

pass synth   "mica-synth 0.1";
pass techmap "mica-map 0.1";
pass pack    "mica-pack 0.1";
```

- `format` command specifies the format version.
- `device` command specifies the model ID of the device for which this netlist is intended.
- `design` is the global name for the design.
- `pass` commands specify which stages this netlist has already passed through, with corresponding tool versions.

The commands must be specified in this exact order.

## Blocks

Netlist has two types of objects: *nets* and *cells*, each one having its own kind of block.
*Nets* correspond to wires, connecting pieces of the design together.
*Cells* are objects with pins, like `$add` or `$mux` or `LUT4`, connected by nets.
Each cell performs some specific operation and has inputs and outputs.

Each of these objects can be configured using one or more *blocks*, with sintax like
```
<object> <name> {
    <command>
    <command>
    ...
}
```
The blocks belonging to the same object are logically combined, allowing you to simply
append a new block to the end of the file instead of adding lines to the old one.
However, the canonical representation only has a single block per object.
The canonical representation first has all net declarations, then all cell blocks, and then all net blocks.
Duplicated commands in an object are not allowed.

Below are descriptions of the objects in more detail.

## Nets

A net is an object representing a connection between several cell pins.
A net always has exactly one source (driver), and one or more sinks (consumers).
Before use, nets must be declared:
```
net my_net_name;
```

Nets are *scalar*: they only represent a single wire, with 1 bit of state.
However, net names can include optional *index*, allowing you to simulate buses as nets with the same name, but different index.
All such nets are still treated by tools as separate objects:
```
net data[0];
net data[1];
net data[2];
net data[3];
```

For convenience, it is possible to declare the whole range of indexed nets in a single declaration.
This is exactly equivalent to the previous syntax:
```
net data[0..3];
```

In fact, a net can have multiple indexes, allowing for multidimensional data:
```
net bus[0..3][0..31];
```
The indexes are still treated as part of the name.

Special clock and reset nets have to be tagged explicitly:
```
net clk1 : clock;
net clk2 : clock;
net rst : reset;
```

Then, the net block is the following:
```
net <name> {
    <command>
    <command>
    ...
}
```

`PERIOD` is a setting for clock networks, specifying their period in picoseconds (as a timing constraint).
Additionally, clock/reset networks can be assigned a `CLK`, `RST` or a specific `PIN`:
```
net clk : clock {
    PERIOD = 10000; // 10 ns, 100 MHz
    CLK = 0;
    PIN = 1;
}

net rst : reset {
    RST = 0;
    PIN = 64;
}
```

The `route` command, added by *router*, describes the physical wires that constitute the net, in bitstream format:

```
net q {
    route {
        switch (0, 2): E.L1[0] = SW.O1A;
        logic  (1, 2): in A1   = O1A;
        io     (0, 3): in O    = S[R].L1[0];
    }
}
```

## Cells

Cell block follows the general format:

```
cell <name> : <type> {
    <command>
    <command>
    ...
}
```

There are two kinds of cell types: logical and physical.
Physical cells correspond directly to cells in Mica FPGA, and are written in capital letters:
`LUT4`, `LUT3`, `FF`, `CARRY`, `MEM`, `MEM_DUAL`, `BRAM`, `BRAM_DUAL`, `DSP`, `DSP_ACC`, `IO`.

Logical cells have names starting from `$`. Their list will be expanded as the toolchain evolves.
So far the only supported logical cells are:
```
$add, $sub, $mul,
$mux, $decode,
$and, $or, $not, $xor,
$and_all, $or_all, $xor_all,
$ff,
$rom, $rom_dual, $ram, $ram_dual,
$input, $output, $bidir,
$blackbox
```

Commands for the cells are either parameter assignments, input/output assignements or memory data.
Parameter assignments look like
```
<PARAMETER> = <value>;
```
Examples:
```
LUT = 0x1234;
SIGNED_A = 1;
```

Inputs and outputs can be assigned to nets:
```
in WE1 = we;
in DI[0] = data[0];
in DI[1] = data[1];
in DI[2] = data[2];
in DI[3] = data[3];
out DO[0] = data_out[0];
out DO[1] = data_out[1];
out DO[2] = data_out[2];
out DO[3] = data_out[3];
```
Buses with the same name can be compressed. Ranges must always be the same length, and are always in increasing order:
```
in WE1 = we;
in DI[0..3] = data[0..3];
out DO[0..3] = data_out[0..3];
```
However, it is possible to assign a single signal to a whole range:
```
in DI[0..3] = data_in;
```

If an input/output bus has width 1, so only `BUS[0]`, then the index can be dropped,
and the input/output can be assigned simply as `BUS`.

Inputs are mandatory, unless specified otherwise.
All outputs are optional.
All inputs can also be assigned to 0 or 1 constants, and buses can be assigned to constants:
```
in WE1 = 1;
in DI[0..3] = 0xF;
```

### Physical cells

Every physical cell can have optional parameters, added by packer and placer:
- `PACK: label` - combines cells with the same label into a single tile.
  Labels can be any identifiers and are autogenerated by packer.
  Not all cells can be packed.
- `SLOT: slot` - slot the cell occupies in the tile, assigned by packer.
  Selection of slots is different for each cell type.
  Not all cells can be packed.
- `SITE: (u32, u32)` - grid position of a tile, assigned by placer.

Below are the per-type parameters, inputs and outputs of all physical cells.

```
LUT4: // LUT part of an LE, 1/2 of a logic tile
    PACK: label? // packer
    SLOT: {LE1, LE2}? // packer
    SITE: (u32, u32)? // placer
    LUT: u16
    in A: net
    in B: net
    in C: net
    in D: net
    out O: net?
LUT3: // Half of the fractured LUT, 1/4 of a logic tile
    PACK: label? // packer
    SLOT: {LE1.A, LE1.B, LE2.A, LE2.B}? // packer
    SITE: (u32, u32)? // placer
    LUT: u8
    in B: net
    in C: net
    in D: net
    out O: net?
FF: // Flip-flop part of an LE, 1/2 of a logic tile
    PACK: label? // packer
    SLOT: {LE1, LE2}? // packer
    SITE: (u32, u32)? // placer
    in CLK: clock
    in RST: reset?
    in D: net
    in E: net
    out Q: net?
CARRY: // LUT part of an LE configured as CARRY, 1/2 of a logic tile
    PACK: label? // packer
    SLOT: {LE1, LE2}? // packer
    SITE: (u32, u32)? // placer
    LUT_P: u8
    LUT_G: u8
    in B: net
    in C: net
    in D: net
    in CIN: net
    out COUT: net?
    out S: net?
    out G: net?
MEM: // Full logic tile configured as distributed RAM (single output)
    SITE: (u32, u32)? // placer
    INIT: u32
    in CLK: clock
    in RST: reset?
    in ADDR[0..4]: net
    in DI: net
    in WE: net
    out DO: net?
MEM_DUAL: // Full logic tile configured as distributed RAM (dual output)
    SITE: (u32, u32)? // placer
    INIT[0..1]: u16
    in CLK: clock
    in RST: reset?
    in ADDR[0..3]: net
    in DI[0..1]: net
    in WE: net
    out DO[0..1]: net?
BRAM: // Full BRAM tile configured as single-port
    SITE: (u32, u32)? // placer
    WIDTH: {1,2,4,8,16}
    data: data{}
    in CLK: clock
    in ADDR[0..ADDR_WIDTH-1]: net // ADDR_WIDTH = log2(4096/WIDTH)
    in DI[0..WIDTH-1]: net
    in WE: net
    out DO[0..WIDTH-1]: net?
BRAM_DUAL: // Full BRAM tile configured as dual-port
    SITE: (u32, u32)? // placer
    WIDTH: {1,2,4,8}
    data: data{}
    in CLK: clock
    in ADDR1[0..ADDR_WIDTH-1]: net // ADDR_WIDTH = log2(4096/WIDTH)
    in ADDR2[0..ADDR_WIDTH-1]: net
    in DI1[0..WIDTH-1]: net
    in DI2[0..WIDTH-1]: net
    in WE1: net
    in WE2: net
    out DO1[0..WIDTH-1]: net?
    out DO2[0..WIDTH-1]: net?
DSP: // Full DSP tile configured as ACC=0
    SITE: (u32, u32)? // placer
    SIGNED_A: u1
    SIGNED_B: u1
    in A[0..7]: net
    in B[0..7]: net
    out O[0..15]: net
DSP_ACC: // Full DSP tile configured as ACC=1
    SITE: (u32, u32)? // placer
    SIGNED_A: u1
    SIGNED_B: u1
    in CLK: clock
    in RST: reset?
    in A[0..7]: net
    in B[0..7]: net
    in C[0..15]: net?
    in MD: net
    in AD: net
    in WE: net
    out O[0..15]: net
IO: // Full IO tile
    PIN: u16? // constraint or placer
    SITE: (u32, u32)? // placer
    PULLUP: u1? = 0
    PULLDOWN: u1? = 0
    in CLK: clock?
    in RST: reset?
    in O: net
    in E: net
    in IE: net? // REG_I = 1 if bound
    in OE: net? // REG_O = 1 if bound
    in EE: net? // Must be bound together with OE
    out I: net?
```

### Logical cells

#### `$add`

Represents an adder, usually implemented via a carry chain.
```
$add:
    WIDTH: u16,
    in A[0..WIDTH-1]: net
    in B[0..WIDTH-1]: net
    in CIN: net
    out O[0..WIDTH-1]: net?
    out COUT: net?
```

#### `$sub`

Represents a subtractor, usually implemented via a carry chain.
```
$sub:
    WIDTH: u16,
    in A[0..WIDTH-1]: net
    in B[0..WIDTH-1]: net
    in CIN: net
    out O[0..WIDTH-1]: net?
    out COUT: net?
```

#### `$mul`

Represents a multiplier, usually implemented via DSPs.
```
$mul:
    WIDTH: u16,
    SIGNED_A: u1,
    SIGNED_B: u1,
    in A[0..WIDTH-1]: net
    in B[0..WIDTH-1]: net
    out O[0..2*WIDTH-1]: net?
```

#### `$mux`

Represents a multiplexer, selecting one of the inputs based on select signal.
```
$mux:
    WIDTH: u16,
    DEPTH: u8,
    in IN[0..2^DEPTH-1][0..WIDTH-1]: net
    in SEL[0..DEPTH-1]: net
    out OUT[0..WIDTH-1]: net?
```

#### `$decode`

Represents a decoder, sending 1 to one of its outputs based on select signal.
All other outputs are set to 0.
```
$decode:
    DEPTH: u8,
    in SEL[0..DEPTH-1]: net
    out OUT[0..2^DEPTH-1]: net?
```

#### `$and`

Represents an AND gate of any width.
```
$and:
    WIDTH: u16
    in A[0..WIDTH-1]: net
    in B[0..WIDTH-1]: net
    out OUT[0..WIDTH-1]: net?
```

#### `$or`

Represents an OR gate of any width.
```
$or:
    WIDTH: u16
    in A[0..WIDTH-1]: net
    in B[0..WIDTH-1]: net
    out OUT[0..WIDTH-1]: net?
```

#### `$xor`

Represents a XOR gate of any width.
```
$xor:
    WIDTH: u16
    in A[0..WIDTH-1]: net
    in B[0..WIDTH-1]: net
    out OUT[0..WIDTH-1]: net?
```

#### `$not`

Represents a NOT gate of any width.
```
$not:
    WIDTH: u16
    in IN[0..WIDTH-1]: net
    out OUT[0..WIDTH-1]: net?
```

#### `$and_all`

Represents a reducing AND gate of N inputs and 1 output.
```
$and_all:
    N: u16
    in IN[0..N-1]: net
    out OUT: net?
```

#### `$or_all`

Represents a reducing OR gate of N inputs and 1 output.
```
$or_all:
    N: u16
    in IN[0..N-1]: net
    out OUT: net?
```

#### `$xor_all`

Represents a reducing XOR gate of N inputs and 1 output.
```
$xor_all:
    N: u16
    in IN[0..N-1]: net
    out OUT: net?
```

#### `$ff`

Represents a D Flip-Flop of any width, with optional synchronous reset
```
$ff:
    WIDTH: u16
    in CLK: clock
    in RST: reset?
    in D[0..WIDTH-1]: net
    in E: net
    out Q[0..WIDTH-1]: net?
```

#### `$rom`

Represents a single-port ROM (implemented either as distributed RAM or block RAM).
```
$rom:
    DATA_WIDTH: u16
    ADDR_WIDTH: u16
    data: data{}
    in A[0..ADDR_WIDTH-1]: net
    out DO[0..DATA_WIDTH-1]: net?
```

#### `$rom_dual`

Represents a dual-port ROM (implemented either as distributed RAM or block RAM).
```
$rom_dual:
    DATA_WIDTH: u16
    ADDR_WIDTH: u16
    data: data{}
    in A1[0..ADDR_WIDTH-1]: net
    in A2[0..ADDR_WIDTH-1]: net
    out DO1[0..DATA_WIDTH-1]: net?
    out DO2[0..DATA_WIDTH-1]: net?
```

#### `$ram`

Represents a single-port RAM (implemented either as distributed RAM or block RAM).
```
$ram:
    DATA_WIDTH: u16
    ADDR_WIDTH: u16
    data: data{}
    in CLK: clock
    in RST: reset?
    in A[0..ADDR_WIDTH-1]: net
    in DI[0..DATA_WIDTH-1]: net
    in WE: net
    out DO[0..DATA_WIDTH-1]: net?
```

#### `$ram_dual`

Represents a dual-port RAM (implemented either as distributed RAM or block RAM).
```
$ram_dual:
    DATA_WIDTH: u16
    ADDR_WIDTH: u16
    data: data{}
    in CLK: clock
    in RST: reset?
    in A1[0..ADDR_WIDTH-1]: net
    in A2[0..ADDR_WIDTH-1]: net
    in DI1[0..DATA_WIDTH-1]: net
    in DI2[0..DATA_WIDTH-1]: net
    in WE1: net
    in WE2: net
    out DO1[0..DATA_WIDTH-1]: net?
    out DO2[0..DATA_WIDTH-1]: net?
```

#### `$input`

Represents a general IO bus, configured as input.
```
$input:
    WIDTH: u16,
    PIN[0..WIDTH-1]: u32?
    PULLDOWN: u1? = 0
    PULLUP: u1? = 0
    in CLK: clock?
    in RST: reset?
    in IE: net? // REG_I = 1 if bound
    out I[0..WIDTH-1]: net?
```

#### `$output`

Represents a general IO bus, configured as output.
```
$output:
    WIDTH: u16,
    PIN[0..WIDTH-1]: u32?
    in CLK: clock?
    in RST: reset?
    in O[0..WIDTH-1]: net
    in E: net
    in OE: net? // REG_O = 1 if bound
    in EE: net? // Must be bound together with OE
```

#### `$bidir`

Represents a general IO bus, configured as bidirectional input-output.
```
$bidir:
    WIDTH: u16,
    PIN[0..WIDTH-1]: u32?
    PULLDOWN: u1? = 0
    PULLUP: u1? = 0
    in CLK: clock?
    in RST: reset?
    in O[0..WIDTH-1]: net?
    in E: net?
    in IE: net? // REG_I = 1 if bound
    in OE: net? // REG_O = 1 if bound
    in EE: net? // Must be bound together with OE
    out I[0..WIDTH-1]: net?
```

#### `$blackbox`

Some unknown cell with implementation-defined behavior. Cannot be placed/positioned/routed.
Any parameters or inputs/outputs are supported.

### Packing rules

There are several rules any packed configuration must follow:
- No overlapping for each cell type: you can't put two `LUT3`'s in the same `SLOT` of a `PACK`,
  and you can't put two `FF`'s in the same `SLOT` either.
- No overlapping between `LUT3` and `LUT4`: either `LUT4` uses `LEn`, or 1 or 2 `LUT3`s use `LEn.X`,
  not both at the same time.
- A `FF` *must* be packed with either `LUT4` or `LUT3` in the same slot
  (`LEn` for `LUT4`, `LEn.A` for `LUT3`).
- `CARRY`s connected by `CIN`/`COUT` should be packed in the same `PACK`,
  or placed adjacent to each other by the placer, to form a correct carry chain.

